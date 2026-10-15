# CLAUDE.md

iOS app that reads heart rate and step data from Apple Health (HealthKit) and uploads it to a
self-hosted Nocturne instance (https://github.com/nightscout/nocturne). Single user, personal use,
read-only on the HealthKit side. Working name: `NocturneSync` (rename freely).

Status: greenfield. No code exists yet. Before the first implementation step, confirm the
"Open decisions" section with the user rather than picking silently.

## Scope

In scope:
- Read `HKQuantityType(.heartRate)` and `HKQuantityType(.stepCount)`.
- Upload to Nocturne V4 endpoints `POST /api/v4/HeartRate` and `POST /api/v4/StepCount`.
- Background sync via HealthKit background delivery, with `BGAppRefreshTask` as fallback.
- Initial backfill over a bounded window, then incremental sync.
- OAuth login against the Nocturne instance.

Out of scope (do not add without asking):
- Writing anything to HealthKit.
- Glucose, insulin, carbs, workouts, sleep, HRV. The architecture should make adding a type cheap,
  but do not implement extra types speculatively.
- Propagating HealthKit deletions to Nocturne (V4 deletes by Nocturne id, not by sync identifier;
  would need a local id map). Known gap, document it, don't half-solve it.
- watchOS app, widgets, analytics, crash reporting SDKs, any third-party telemetry.

## Stack and conventions

- Swift 6 language mode, strict concurrency complete. No `@unchecked Sendable` or
  `nonisolated(unsafe)` without a comment justifying it.
- SwiftUI, iOS 18 minimum. `@Observable` for view models; no Combine.
- No third-party dependencies by default. Each proposed dependency needs a one-line justification.
- Project file generated with XcodeGen (`project.yml`). Never hand-edit `.pbxproj`; edit
  `project.yml` and regenerate. `*.xcodeproj` is gitignored.
- Formatting: `swift format` (toolchain-bundled). Run before every commit.
- Tests: Swift Testing (`import Testing`), not XCTest, except where UI tests require XCTest.
- Logging: `os.Logger` with a subsystem per module. Health values and tokens are always
  `privacy: .private`. Never `print`.
- Errors: typed domain errors per layer; no `try?` that swallows a sync failure.

## Commands

```sh
xcodegen generate
xcodebuild -scheme NocturneSync -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -scheme NocturneSync -destination 'platform=iOS Simulator,name=iPhone 16' test
swift format --in-place --recursive Sources Tests
```

Update this section when targets or schemes change.

## Architecture

Three layers, dependency direction strictly downward. Domain types are plain `Sendable` structs.

```
App (SwiftUI, settings, auth UI)
 └─ SyncEngine (actor)        orchestrates per-type sync, owns anchors, retry, scheduling
     ├─ HealthSource          protocol over HealthKit; live impl + fake for tests
     ├─ NocturneClient        protocol over the V4 API; URLSession impl + fake for tests
     └─ Stores                AnchorStore (file), TokenStore (Keychain)
```

- One `SyncEngine` actor is the only writer of anchors and the only caller of the upload client.
  Background delivery callbacks, BG tasks, and manual "Sync now" all funnel into it.
- Per data type, a small `SyncPipeline` (read → map → batch → upload → commit). Adding a type
  means adding a pipeline, not touching the engine.
- `HealthSource` and `NocturneClient` are protocols so the engine is fully testable without
  HealthKit or a network.

## HealthKit rules

- Request read authorization only. `NSHealthShareUsageDescription` in Info.plist; no
  `NSHealthUpdateUsageDescription`. HealthKit does not reveal whether read access was denied;
  an empty result is not an error. Surface "no data seen yet" in the UI instead of guessing.
- Entitlements: HealthKit, plus `com.apple.developer.healthkit.background-delivery`.
- Register an `HKObserverQuery` per type and call `enableBackgroundDelivery` at every launch
  (registrations do not survive reinstalls). Always call the observer's completion handler,
  including on failure, or iOS throttles further deliveries.
- Do not assume delivery frequency. iOS caps some types (step count among them) at hourly
  regardless of the requested frequency.
- The HealthKit store is unreadable while the device is locked. Treat
  `HKError.errorDatabaseInaccessible` as "retry later": do not advance anchors, do not surface
  an error.
- Persist state so it is readable after first unlock in the background:
  anchors with file protection `.completeUntilFirstUserAuthentication`, Keychain items with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

### Heart rate

- `HKAnchoredObjectQuery` with a persisted `HKQueryAnchor` (NSSecureCoding, archived to a file).
- One sample → one Nocturne record. `bpm` = sample value in count/min, rounded to Int.
- `syncIdentifier` = `sample.uuid.uuidString`.
- Advance the anchor only after every batch derived from that query result got a 2xx.
- Watch workouts produce dense samples (seconds apart). Upload raw; do not downsample unless the
  user decides otherwise.

### Steps (the part most likely to be gotten wrong)

- Do NOT upload raw step samples. iPhone and Apple Watch both record steps for the same period;
  summing raw samples double-counts. Use `HKStatisticsCollectionQuery` with `.cumulativeSum`,
  which applies Health's source prioritization.
- Fixed buckets (default 5 min, aligned to the epoch, not to local time).
  `syncIdentifier` = `"steps-<bucketStartUnixSeconds>-<bucketSeconds>"`.
- Statistics queries have no anchor. Instead, each sync recomputes a rolling lookback window
  (default 24 h) and re-uploads every non-empty bucket in it. Upsert-by-syncIdentifier makes this
  idempotent; the lookback covers late Watch syncs. Persist only "backfill completed up to".
- `source` bitmask: send `0` (bit 0 clear = per-interval delta, bit 1 clear = safe to sum).
  Never set bit 1.
- Use the observer query only as a trigger; the statistics query does the reading.

## Nocturne API contract

Verified against Nocturne `main` as of 2026-10 (latest release v0.2.3; pre-1.0, expect churn).
Re-verify against the instance's Scalar docs (`/scalar`) before changing the client, and record
the Nocturne version tested against in `docs/compat.md`.

- Base URL is the tenant URL (e.g. `https://<slug>.<base-domain>`), user-configured.
- Endpoints: `POST /api/v4/HeartRate`, `POST /api/v4/StepCount`. Body is a JSON array.
  Max 1000 records per request (server returns 400 above that). Chunk at 500.
- Heart rate request fields: `timestamp` (ISO 8601 with offset), `utcOffset` (minutes),
  `bpm` (int), `accuracy` (int, send 0 unless a real value exists), `device`, `app`,
  `dataSource`, `syncIdentifier`.
- Step count request fields: `timestamp`, `utcOffset`, `metric` (int), `source` (int bitmask),
  `device`, `app`, `dataSource`, `syncIdentifier`.
- Dedup: `(dataSource, syncIdentifier)` is unique per tenant; re-uploading updates in place.
  `dataSource` is a single constant, `"apple-health-ios"`. Never change it after first release;
  doing so duplicates all history.
- `utcOffset`: from `HKMetadataKeyTimeZone` when present, else the device time zone at the
  sample's timestamp (DST-correct via `TimeZone.secondsFromGMT(for:)`).
- Hand-roll a thin `URLSession` client for these two endpoints plus OAuth. The official
  generated SDK (`nightscout/nocturne-swift`) is a reference for model shapes, not a dependency,
  unless the user decides otherwise.

### Auth

- OAuth 2.0 Authorization Code + PKCE via `ASWebAuthenticationSession`. Public client, no secret.
- Dynamic client registration: `POST /api/oauth/register` with a fixed `software_id`
  (bundle id) and the app's redirect URI. Idempotent per tenant; cache `client_id` per base URL.
- Scopes: `heartrate.readwrite stepcount.readwrite`. Request nothing broader.
- Refresh tokens rotate, and replaying an old one revokes the whole grant. Token refresh must be
  single-flight: one actor owns the token, concurrent callers await the same refresh task, and
  the new refresh token is persisted to Keychain before the access token is used.
- 401 → refresh once, retry once. 403 → scope problem, surface to user, stop syncing.
  `503 setup_required` → instance not set up, surface to user.

## Sync semantics

- At-least-once delivery. Correctness comes from server-side upsert, not from client
  bookkeeping. Any change that would break idempotency needs explicit sign-off.
- Initial backfill: bounded window (default 30 days, configurable), oldest first, chunked so a
  single background execution can make progress and resume.
- Retries: exponential backoff with jitter for 5xx and network errors; no retry for 4xx other
  than 401/429. Respect `Retry-After`.
- Background time is short. A sync run must be cancellable at any batch boundary without
  losing committed progress.
- Record per-type `lastSuccessfulSync`, `lastError`, and record counts for the status screen.

## Testing

- Unit-test mapping (units, rounding, offsets, DST edges, bucket alignment, syncIdentifier
  stability), chunking, anchor-commit-only-on-success, single-flight refresh, and retry policy
  against fakes.
- Simulator has HealthKit but no realistic background delivery. Background behaviour is verified
  on device only; say so in PRs instead of claiming it was tested.
- Integration target against a local Nocturne (`aspire start` in a Nocturne checkout; API on
  `http://localhost:1610`). Seed a tenant with `POST /api/v4/dev-only/admin/seed-tenant` and get
  a token from `GET /api/v4/dev-only/auth/login?tenant=<slug>&format=json`. Dev-only endpoints
  exist only in Development; never reference them from app code.
- Never commit real health data, tokens, or instance URLs as fixtures.

## Working rules for Claude

- Small, reviewable steps. One pipeline or one layer per change.
- Before touching HealthKit query or background-delivery code, state which Apple behaviour you
  are relying on; if unsure, say so instead of asserting.
- Do not invent Nocturne fields or endpoints. If the contract above looks wrong or stale, check
  the Nocturne source and update this file in the same change.
- This is not a medical device. No UI that interprets values clinically.

## Open decisions (ask before implementing)

1. Step bucket size (5 min proposed) and lookback window (24 h proposed).
2. Backfill window (30 days proposed).
3. Heart rate: raw upload vs. downsampling during workouts.
4. Hand-rolled client vs. `nocturne-swift` SDK.
5. Auth flow: PKCE via `ASWebAuthenticationSession` (proposed) vs. Nocturne's device flow.
6. Minimum iOS version (18 proposed).
