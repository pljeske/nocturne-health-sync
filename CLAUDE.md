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
- Honouring deletions made in Nocturne. The HeartRate/StepCount upsert path ignores soft-deleted
  rows, so a record the user deletes in Nocturne is re-inserted by the next upload (for steps,
  within one lookback window). Document it; do not try to track server-side deletions.
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
     └─ Stores                AnchorStore (file), TokenStore (Keychain), SyncStateStore (file)
```

`SyncStateStore` holds the step backfill watermark, per-type status (`lastSuccessfulSync`,
`lastError`, counts), and the cached OAuth `client_id` per base URL. Only `SyncEngine` writes it.

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
- Always pass a `limit` (default 2000 samples) so each query result is uploadable within one
  background execution. Loop until the result is short of the limit. Without a limit, a workout-
  heavy backfill returns tens of thousands of samples and the anchor never commits.
- One sample → one Nocturne record. `bpm` = sample value in count/min, rounded to Int.
- `syncIdentifier` = `sample.uuid.uuidString`.
- Advance the anchor only after every batch derived from that query result got a 2xx.
- Watch workouts produce dense samples (seconds apart). Upload raw, no downsampling (decided).
  Expect bursts of thousands of samples per workout; the query limit and chunking above handle it.

### Steps (the part most likely to be gotten wrong)

- Do NOT upload raw step samples. iPhone and Apple Watch both record steps for the same period;
  summing raw samples double-counts. Use `HKStatisticsCollectionQuery` with `.cumulativeSum`,
  which applies Health's source prioritization.
- Fixed 5 min buckets, aligned to the epoch, not to local time (decided, see below).
  `syncIdentifier` = `"steps-<bucketStartUnixSeconds>-<bucketSeconds>"`. Because the bucket size
  is part of the identifier, changing it after first release creates a second series that the
  server sums alongside the old one. Treat it like `dataSource`: fixed forever.
- Statistics queries have no anchor. Instead, each sync recomputes a rolling 24 h lookback window
  and re-uploads every non-empty bucket in it. Upsert-by-syncIdentifier makes this idempotent; the
  lookback covers late Watch syncs. The only persisted step state is "backfill completed up to"
  (in `SyncStateStore`).
- A bucket that was non-empty once and later drops to zero in Health is never zeroed on the
  server. Known gap, document it.
- `source` bitmask: send `0` (bit 0 clear = per-interval delta, bit 1 clear = safe to sum).
  Never set bit 1.
- Use the observer query only as a trigger; the statistics query does the reading.

## Nocturne API contract

Verified against Nocturne `main` at commit 806cb31 (2026-10-14; latest release v0.2.7; pre-1.0,
expect churn). Re-verify against the instance's Scalar docs (`/scalar`) before changing the
client, and record the Nocturne version tested against in `docs/compat.md`.

- Base URL is the tenant URL (e.g. `https://<slug>.<base-domain>`), user-configured.
- Endpoints: `POST /api/v4/HeartRate`, `POST /api/v4/StepCount`. Body is a JSON array.
  Max 1000 records per request; an empty array is also a 400. Chunk at 500, never send an empty
  chunk. Success is 200 with the written records; treat any 2xx as success.
- Errors are RFC 7807 Problem Details (`title`, `detail`, `status`). Show `detail` on the status
  screen.
- Heart rate request fields: `timestamp` (ISO 8601 with offset), `utcOffset` (minutes),
  `bpm` (int), `accuracy` (int, send 0 unless a real value exists), `device`, `app`,
  `dataSource`, `syncIdentifier`. The server stores `timestamp` as UTC and discards the offset;
  `utcOffset` is the only carrier of local time.
- `device` = `sample.sourceRevision.productType` falling back to the source name; `app` = the app
  name plus marketing version (maps to Nocturne's `enteredBy`).
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
  (bundle id) and the app's redirect URI. Idempotent per `(tenant, software_id)`. Registration
  is rate-limited to 10 per hour per IP, so caching `client_id` per base URL is mandatory and
  registration must never sit in a retry loop.
- Redirect URI: Nocturne accepts only a custom scheme containing a dot (reverse-DNS, e.g.
  `<bundle-id>://oauth/callback`), an https URL, or http loopback. Fragments are rejected.
  Use the bundle id as the scheme.
- Scopes: `heartrate.readwrite stepcount.readwrite`. Request nothing broader. PKCE is mandatory,
  `S256` only.
- Refresh tokens rotate, and replaying an old one revokes the whole grant. Token refresh must be
  single-flight: one actor owns the token, concurrent callers await the same refresh task, and
  the new refresh token is persisted to Keychain before the access token is used.
- Refresh tokens expire 90 days after issue. A device idle longer than that needs a new login.
- 401 → refresh once, retry once. A refresh that fails with 400 `invalid_grant` means the grant
  is gone: sign out, stop syncing, surface to user. 403 → scope problem, surface to user, stop
  syncing. 503 with `error` `setup_required` or `recovery_mode_active` → instance not usable,
  surface to user, retry later.

## Sync semantics

- At-least-once delivery. Correctness comes from server-side upsert, not from client
  bookkeeping. Any change that would break idempotency needs explicit sign-off.
- Initial backfill: 90 days (decided), oldest first, chunked so a single background execution
  can make progress and resume.
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

## Decisions

Decided 2026-10-15:

1. Step bucket size 5 min, lookback window 24 h. The bucket size is permanent (see Steps).
2. Backfill window 90 days.
3. Heart rate: raw upload, no downsampling during workouts.

## Open decisions (ask before implementing)

4. Hand-rolled client vs. `nocturne-swift` SDK. Review 2026-10-15: the SDK is OpenAPI Generator
   output (API version 0.0.1, README still documents Carthage/CocoaPods), covers both endpoints,
   does nothing for PKCE or refresh. Recommendation: hand-roll.
5. Auth flow: PKCE via `ASWebAuthenticationSession` vs. Nocturne's device flow
   (`/api/oauth/device`). The device flow targets input-constrained devices. Recommendation: PKCE.
6. Minimum iOS version (18 proposed). Nothing in the stack needs more than 17.
