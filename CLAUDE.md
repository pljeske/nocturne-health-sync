# CLAUDE.md

iOS app that reads heart rate, step and sleep data from Apple Health (HealthKit) and uploads it to a
self-hosted Nocturne instance (https://github.com/nightscout/nocturne). Single user, personal use,
read-only on the HealthKit side. Working name: `NocturneSync` (rename freely).

Status: in progress, following `docs/plan.md` step by step. All design decisions are recorded in
the "Decisions" section; anything not covered there is a new decision and must be asked, not
picked silently.

## Scope

In scope:
- Read `HKQuantityType(.heartRate)`, `HKQuantityType(.stepCount)` and `HKCategoryType(.sleepAnalysis)`,
  plus `heartRateVariabilitySDNN`, `respiratoryRate` and `oxygenSaturation` for sleep summaries only.
- Upload to Nocturne V4 endpoints `POST /api/v4/HeartRate`, `POST /api/v4/StepCount` and
  `POST /api/v4/sleep/sessions/bulk`.
- Background sync via HealthKit background delivery, with `BGAppRefreshTask` as fallback.
- Initial backfill over a bounded window, then incremental sync.
- OAuth login against the Nocturne instance.

Out of scope (do not add without asking):
- Writing anything to HealthKit.
- Glucose, insulin, carbs, workouts. HRV, SpO2 and respiratory rate as series of their own, and the
  per-sample `biometricSamples` of a sleep session: they are sent only as sleep session averages
  (decision 14). The architecture should make adding a type cheap, but do not implement extra types
  speculatively.
- Propagating HealthKit deletions to Nocturne (V4 deletes by Nocturne id, not by sync identifier;
  would need a local id map). Known gap, document it, don't half-solve it.
- Honouring deletions made in Nocturne. The HeartRate/StepCount upsert path ignores soft-deleted
  rows, so a record the user deletes in Nocturne is re-inserted by the next upload (for steps,
  within one lookback window). Sleep differs: a user-deleted session is a tombstone the server
  refuses to recreate (silently on `main`, 409 for the whole request on v0.2.7). Document it; do not
  try to track server-side deletions.
- Deleting orphaned sleep sessions. A sleep day whose session count shrinks leaves its highest
  position name on the server; the bulk response carries the ids needed to delete it, but tracking
  them is deletion propagation. Known gap, document it.
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

Swift package (`NocturneSyncCore` and `NocturneSyncFeatures`, Foundation + Observation only; works on
macOS and Linux, including Claude Code cloud sessions, where `.claude/hooks/session-start.sh`
installs a Swift 6 toolchain to `/opt/swift`):

```sh
swift build
swift test
swift format lint --strict --recursive Sources Tests Package.swift
swift format --in-place --recursive Sources Tests Package.swift
```

Integration tests against a local development Nocturne (skipped unless the URL is set; see
`docs/integration.md`):

```sh
NOCTURNE_INTEGRATION_URL=<tenant url> NOCTURNE_INTEGRATION_TOKEN=<token> \
  swift test --filter NocturneSyncIntegrationTests
```

App target (Mac with Xcode 16+ only; `xcodegen generate` first, the project is not committed):

```sh
xcodegen generate
xcodebuild -scheme NocturneSync -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -scheme NocturneSync -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Set `DEVELOPMENT_TEAM` in the environment before `xcodegen generate` for device builds.
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

`SyncStateStore` holds the step backfill watermark and per-type status (`lastSuccessfulSync`,
`lastError`, counts). Only `SyncEngine` writes it. `TokenStore` holds the `TokenSet` and the cached
OAuth `client_id`, both keyed by instance base URL; only `AuthSession` writes it (sign-in happens
before any engine runs). Anchors and sync state live in a directory per instance
(`StoreLocation`), so a different instance starts its own backfill.

- One `SyncEngine` actor is the only writer of anchors and the only caller of the upload client.
  Background delivery callbacks, BG tasks, and manual "Sync now" all funnel into it.
- Per data type, a small `SyncPipeline` (read → map → batch → upload → commit). Adding a type
  means adding a pipeline, not touching the engine.
- `HealthSource` and `NocturneClient` are protocols so the engine is fully testable without
  HealthKit or a network.
- The app layer's logic lives in the `NocturneSyncFeatures` package target: `AppModel`
  (`@Observable`, the single entry point for launch, sign-in, Health observers, BG refresh, "Sync
  now", sign-out), status presentation and instance URL parsing, against small protocols
  (`AuthService`, `SyncService`, `WebAuthenticating`, `BackgroundScheduling`, `SettingsStore`).
  The iOS target (`Sources/NocturneSync`) holds only Apple-framework glue: `HealthKitSource`,
  `KeychainTokenStore`, BGTaskScheduler, the `ASWebAuthenticationSession` adapter, SwiftUI views,
  and `LiveEnvironment`, the composition root. Keep new logic out of the iOS target.

## HealthKit rules

- Request read authorization only. `NSHealthShareUsageDescription` in Info.plist; no
  `NSHealthUpdateUsageDescription`. HealthKit does not reveal whether read access was denied;
  an empty result is not an error. Surface "no data seen yet" in the UI instead of guessing.
- Entitlements: HealthKit, plus `com.apple.developer.healthkit.background-delivery`.
- Register an `HKObserverQuery` per type and call `enableBackgroundDelivery` at every launch
  (registrations do not survive reinstalls). Always call the observer's completion handler,
  including on failure, or iOS throttles further deliveries.
- Do not assume delivery frequency. iOS caps some types (step count among them) at hourly
  regardless of the requested frequency. Both types request `.hourly` (decision 9).
- Pipelines run steps, then sleep, then heart rate: the cheap passes finish before a long backfill
  that a background time limit may cut short.
- The HealthKit store is unreadable while the device is locked. Treat
  `HKError.errorDatabaseInaccessible` as "retry later": do not advance anchors, do not surface
  an error.
- Persist state so it is readable after first unlock in the background:
  anchors and sync state with file protection `.completeUntilFirstUserAuthentication`, Keychain
  items with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. The store directory is excluded
  from backups: anchors are opaque handles into one device's HealthKit store, and the rest is
  rebuilt by a single sync.

### Heart rate

- `HKAnchoredObjectQuery` with a persisted `HKQueryAnchor` (NSSecureCoding, archived to a file).
- Always pass a `limit` (default 2000 samples) so each query result is uploadable within one
  background execution. Loop until the result is short of the limit. Without a limit, a workout-
  heavy backfill returns tens of thousands of samples and the anchor never commits.
- Every anchored query carries a `startDate >= cutoff` predicate, with the cutoff fixed at the first
  run (decision 7). Anchor order is insertion order, not date order, so an anchor alone does not
  bound a page by date.
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
  and re-uploads the non-empty buckets in it whose total differs from the last send
  (`SyncState.stepLookbackSent`, replaced after each lookback upload); an unchanged window costs no
  request and no disk write. A user-requested run (`SyncContext.userRequested`, from "Sync now")
  re-sends the whole window. Upsert-by-syncIdentifier makes every re-send idempotent; the lookback
  covers late Watch syncs. Persisted step state: the backfill watermark and that map.
- Each run: the lookback window first (no state written), then the backfill `[watermark, lookback
  start)` in one-day (86 400 s) slices, oldest first, committing the watermark after each slice
  until caught up or cancelled. Every boundary is an epoch-aligned bucket start; local time never
  enters the window arithmetic. Buckets that round to zero steps are not uploaded.
- `device` on step records is `"Apple Health"` (decision 8, `NocturneConstants.stepDevice`): a
  bucket is Health's merged total and has no single recording device.
- A bucket that was non-empty once and later drops to zero in Health is never zeroed on the
  server. Known gap, document it.
- `source` bitmask: send `0` (bit 0 clear = per-interval delta, bit 1 clear = safe to sum).
  Never set bit 1.
- Use the observer query only as a trigger; the statistics query does the reading.

### Sleep

- Health stores sleep as `sleepAnalysis` category samples (`inBed`, `asleepUnspecified`, `awake`,
  `asleepCore`, `asleepDeep`, `asleepREM`), one interval each, from every source (Watch stages,
  iPhone "in bed", third-party apps). Nocturne stores sessions. `SleepSessionBuilder` groups samples
  of all sources by time: sorted by start, a sample beginning more than 1 h after the running
  session's latest end starts a new session (decision 11). Overlapping intervals from different
  sources are uploaded as they are; the server counts sleep per stage and `InBed` is neither sleep
  nor awake, so an iPhone in-bed band under Watch stages does not double count.
- Sessions have no HealthKit identity, so they are named by position: `originalId` =
  `sleep-<yyyy-MM-dd>-<n>`, where the date is the sleep day (local noon to the next local noon, in
  the device zone) the session's start falls in and `n` its zero-based index by start within that
  day (decision 12). Only the whole set of a day is stable, so a day's sessions are always uploaded
  together; a late or edited sample changes a session's content, not its name. Permanent, like the
  step bucket size.
- The longest session of a day is `Overnight` with `isMainSleep: true`; the others are `Nap`.
  `detectionMethod` is `Manual` when every sample carries `HKMetadataKeyWasUserEntered`, else `Auto`.
  `timezone` is the first sample's `HKMetadataKeyTimeZone`, else the device zone. `startTime` and
  `endTime` are the earliest start and latest end; totals are sums per stage, with
  `deepSleepMs`/`lightSleepMs`/`remSleepMs` omitted when no stage of the session was differentiated.
- No anchor. Each run rebuilds the lookback window (the current sleep day and the 2 before it) and
  re-sends sessions whose content digest differs from the last send (`SyncState.sleepLookbackSent`);
  "Sync now" re-sends the whole window. Then the backfill `[watermark, lookback start)` one sleep day
  at a time, oldest first, committing the watermark after each day. Samples are read 24 h beyond a
  window on both sides so a session straddling a boundary is grouped whole; a window uploads only
  sessions that start inside it.
- `sourceDevice` is `"Apple Health"` (`NocturneConstants.mergedDevice`, decision 8 applies: a session
  merges iPhone and Watch samples). `source` is `"Apple"` (the server's `SleepSource` member) and,
  with `originalId`, the dedup key: fixed forever.
- Biometrics (decision 14): each session carries `avgHeartRate`, `minHeartRate`, `avgHrv`,
  `avgBreathRate` and `avgSpo2`, from heart rate, `heartRateVariabilitySDNN` (ms), `respiratoryRate`
  and `oxygenSaturation` readings of every source. Health's SpO2 fraction is converted to percent.
  Only readings whose start falls in an asleep stage interval (`Light`, `Deep`, `Rem`, `Asleep`)
  count; in-bed and awake time are excluded. Values are rounded to 0.1. A field is omitted when no
  reading of its kind was taken while asleep; an in-bed-only session has none and costs no query.
  Readings are queried per session over the session's span, never over a window, so daytime workout
  heart rate is never read. The summary is part of the content digest: a late reading re-sends the
  session while it is in the lookback. These types have no observer; the next run that includes
  sleep picks them up. Impossible readings (not finite, negative, SpO2 above 100 %) are skipped and
  logged.
- Per-sample `biometricSamples`, latency, efficiency and scores are not sent. Nothing in Nocturne's
  web app displays per-sample biometrics, and heart rate is already uploaded as its own series.
- A sleep day whose session count drops (a session deleted in Health, two merged by late data)
  leaves its last name orphaned on the server. Known gap, document it.

## Nocturne API contract

Verified against Nocturne `main` at commit c28fdd6 (2026-10-19; latest release v0.2.7; pre-1.0,
expect churn). Heart rate and steps were first verified at 806cb31. Re-verify against the instance's Scalar docs (`/scalar`) before changing the
client, and record the Nocturne version tested against in `docs/compat.md`.

- Base URL is the tenant URL (e.g. `https://<slug>.<base-domain>`), user-configured.
- Endpoints: `POST /api/v4/HeartRate`, `POST /api/v4/StepCount`. Body is a JSON array.
  Max 1000 records per request; an empty array is also a 400. Chunk at 500, never send an empty
  chunk. Success is 200 with the written records; treat any 2xx as success.
- Errors are RFC 7807 Problem Details (`title`, `detail`, `status`). Show `detail` on the status
  screen.
- The setup gate answers 503 outside Problem Details: `{ "error": "setup_required" |
  "recovery_mode_active", "message", "setupRequired", "recoveryMode" }` (`TenantSetupMiddleware`).
  Any other 503 is an ordinary server error.
- Heart rate request fields: `timestamp` (ISO 8601 with offset), `utcOffset` (minutes),
  `bpm` (int), `accuracy` (int, send 0 unless a real value exists), `device`, `app`,
  `dataSource`, `syncIdentifier`. The server stores `timestamp` as UTC and discards the offset;
  `utcOffset` is the only carrier of local time.
- `device` = `sample.sourceRevision.productType` falling back to the source name; `app` = the app
  name plus marketing version, `NocturneSync <version>` (maps to Nocturne's `enteredBy`). The app
  target supplies the version to `SyncEngine`.
- Step count request fields: `timestamp`, `utcOffset`, `metric` (int), `source` (int bitmask),
  `device`, `app`, `dataSource`, `syncIdentifier`.
- Sleep: `POST /api/v4/sleep/sessions/bulk` takes a JSON array of `SleepSession` (`SleepController`),
  max 100 per request, empty array is 400; answers 201 with the stored sessions. Chunk at 20 (each
  session embeds its stages). Dedup is `(source, originalId)` per tenant, in the repository, not
  a `dataSource`/`syncIdentifier` pair; a re-upload replaces the whole row including stages and
  keeps its id. 409 means a concurrent insert (not retried; this app is the only writer) and, on
  v0.2.7, a session the user deleted. Fields sent: `startTime`, `endTime` (UTC, `Z` suffix: these are
  `DateTime`, an offset form would be shifted to server-local time and rejected by UTC-only storage),
  `timezone` (IANA), `type` (`Overnight`/`Nap`), `detectionMethod` (`Auto`/`Manual`), `isMainSleep`,
  `durationMs`, `totalSleepMs`, `totalAwakeMs`, `deepSleepMs`, `lightSleepMs`, `remSleepMs`,
  `avgHeartRate`, `minHeartRate` (bpm), `avgHrv` (ms), `avgBreathRate` (breaths/min), `avgSpo2`
  (percent, 0 to 100; floats on the server, shown on the single-night report), `source` (`Apple`), `sourceDevice`, `sourceApp` (same value as `app`), `originalId`, `stages`
  (`startTime`, `endTime`, `stage` of `InBed`/`Asleep`/`Awake`/`Light`/`Deep`/`Rem`/`Unknown`,
  `ordinal`). Enums are serialised by name (`JsonStringEnumConverter`).
- Dedup: `(dataSource, syncIdentifier)` is unique per tenant; re-uploading updates in place.
  `dataSource` is a single constant, `"apple-health-ios"`. Never change it after first release;
  doing so duplicates all history.
- `utcOffset`: from `HKMetadataKeyTimeZone` when present, else the device time zone at the
  sample's timestamp (DST-correct via `TimeZone.secondsFromGMT(for:)`).
- Hand-roll a thin `URLSession` client for these two endpoints plus OAuth (decided). The
  generated SDK (`nightscout/nocturne-swift`) is a reference for model shapes, not a dependency.

### Auth

- OAuth 2.0 Authorization Code + PKCE via `ASWebAuthenticationSession` (decided; not the device
  flow). Public client, no secret.
- Dynamic client registration: `POST /api/oauth/register` with a fixed `software_id`
  (bundle id) and the app's redirect URI. Idempotent per `(tenant, software_id)`. Registration
  is rate-limited to 10 per hour per IP, so caching `client_id` per base URL is mandatory and
  registration must never sit in a retry loop.
- Redirect URI: Nocturne accepts only a custom scheme containing a dot (reverse-DNS, e.g.
  `<bundle-id>://oauth/callback`), an https URL, or http loopback. Fragments are rejected.
  Use the bundle id as the scheme.
- Scopes: `heartrate.readwrite stepcount.readwrite sleep.readwrite`. Request nothing broader. PKCE is
  mandatory, `S256` only. `authorize` validates scopes against the server's list and the existing
  grant, not against the registered client, so a cached `client_id` works after a scope is added;
  the user sees the consent page again for the upgrade. A token from before a scope was added gets
  403 on that endpoint: the status screen tells the user to sign out and in again.
- Wire shapes (`OAuthController`): `register` takes JSON (`client_name`, `redirect_uris`, `scope`,
  `software_id`, `software_version`) and returns `client_id`; `token` and `revoke` take
  `application/x-www-form-urlencoded`; `token` returns `access_token`, `expires_in`,
  `refresh_token`, `scope`. OAuth errors are 400 `{ "error", "error_description" }`, not Problem
  Details. The callback carries `code`/`state` or `error`/`error_description`, percent-encoded.
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
- Progress is published while a run works, not only at its end: `SyncEngine.events` yields
  started / progressed (after every committed batch, with the new state) / finished per type.
  Steps report a real fraction of the run's backfill; heart rate reports counts and the newest
  sample date only, since anchor order gives no total. One consumer: `AppModel`.
- Runs never overlap. A request during a run queues one follow-up; later requests join it. An
  observer trigger runs only its type; launch, manual and background refresh run all types.
- Resource budget: the app does nothing on its own. It runs only when iOS wakes it (hourly Health
  delivery, or the `BGAppRefreshTask` fallback requested 4 h out after each run) or the user opens
  it; a run with nothing new makes no request and writes no file beyond the status timestamp; no
  timers, polling, or open connections. Health access is requested once per process.
- A failure that is not type-specific (signed out, 401 after refresh, setup/recovery gate, no
  network, 429, locked device, local storage) ends the whole run; others end only that type.
- A sample that cannot be mapped (NaN, negative, out of range) is skipped and logged, never
  retried: one bad sample must not pin the anchor forever.

## Testing

- Unit-test mapping (units, rounding, offsets, DST edges, bucket alignment, syncIdentifier
  stability), sleep day boundaries across DST, session grouping and naming, sleep biometric
  averaging (asleep-only, units, skipped readings), chunking,
  anchor-commit-only-on-success, single-flight refresh, and retry policy against fakes.
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
4. Hand-rolled `URLSession` client, not the `nocturne-swift` SDK. The SDK is OpenAPI Generator
   output (API version 0.0.1, README still documents Carthage/CocoaPods) and does nothing for
   PKCE or refresh.
5. Auth flow: Authorization Code + PKCE via `ASWebAuthenticationSession`. Nocturne's device flow
   (`/api/oauth/device`) targets input-constrained devices and is not used.
6. Minimum iOS version 18.

Decided 2026-10-16:

7. Heart rate cutoff is fixed: the first run persists `now - 90 d` (`SyncState.heartRateBackfillStart`)
   and every anchored query uses it forever. Incremental sync uploads everything new, even after a
   long idle period; nothing older than the original backfill start is ever uploaded.
8. Step records carry `device` = `"Apple Health"`: the value is Health's merged total, not one
   device's reading. Not part of the dedup key, so it can change without duplicating data.

Decided 2026-10-17:

9. Heart rate background delivery is `.hourly`, not `.immediate`. Immediate would relaunch the app
   in the background on every Watch sync of a few samples, many times an hour, for data that is
   viewed retrospectively. Costs up to an hour of latency; one line to revert.

Decided 2026-10-19 (sleep, requested by the user; the details below were chosen while implementing
and are open to revision until the first release, after which 12 is permanent):

10. Sleep is in scope: `sleepAnalysis` samples become Nocturne sleep sessions via
    `POST /api/v4/sleep/sessions/bulk`, scope `sleep.readwrite`. Same 90-day backfill.
11. Sessions are formed across all sources by a 1 h gap rule (see Sleep). Overlapping intervals from
    different sources are kept, not merged or prioritised.
12. Session identity is `sleep-<sleep day>-<position>`, with sleep days running local noon to noon.
    Chosen over a start-based name because edits in Health and late earlier samples then change
    content, not identity; the cost is a local-calendar dependency and an orphan when a day's session
    count shrinks.
13. The longest session of a sleep day is the overnight (main) sleep; sleep lookback is the current
    day plus 2; sleep background delivery is `.hourly` like the rest.

Decided 2026-10-19 (sleep biometrics, requested by the user):

14. Sleep sessions carry the five summary fields (average and minimum heart rate, average HRV,
    breathing rate and SpO2). Averages cover asleep stage intervals only, chosen because in-bed and
    awake time raise them. Per-sample `biometricSamples` are not sent. No new OAuth scope; three new
    Health read types.

No decisions are currently open.
