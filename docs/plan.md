# Implementation plan

Plan for building `NocturneSync` as specified in `CLAUDE.md`. Each step is one reviewable change
(one layer or one pipeline), lands on its own branch, and leaves `main` building and green.
Steps are ordered by dependency; nothing in a step requires a later step.

## Where things can be verified

| Environment | Can do | Cannot do |
| --- | --- | --- |
| Cloud session, no toolchain (today) | Write code, docs, `project.yml` | Compile anything |
| Cloud session, Swift 6 Linux toolchain | Build and test `NocturneSyncCore` | HealthKit, Keychain, SwiftUI, XcodeGen |
| Mac, Xcode 16+ | All of `Commands`, simulator tests | Realistic background delivery |
| iPhone | Background delivery, BG tasks, locked device | Nothing relevant |

Consequence for the layout: everything that does not touch HealthKit, Keychain, or SwiftUI lives
in a SwiftPM package (`NocturneSyncCore`) that compiles with Foundation only. The app target is a
thin shell. A cloud session can then write and test the core, and a Mac is needed only for the
adapters and the UI. Optional step 0b installs a Linux toolchain in the cloud environment via a
SessionStart hook so core tests run there too.

## Repository layout

```
project.yml                         XcodeGen spec (app + UI test target)
Package.swift                       NocturneSyncCore package
Sources/NocturneSyncCore/           pure Swift, Foundation only
  Domain/                           records, bucket math, offsets, errors
  Client/                           NocturneClient protocol, URLSession impl, DTOs, chunking
  Auth/                             OAuthClient, AuthSession actor, PKCE
  Stores/                           store protocols + file-backed implementations
  Engine/                           SyncEngine actor, pipelines, retry policy
Sources/NocturneSync/               iOS app target
  App/                              entry point, scene, launch wiring, BG task registration
  HealthKit/                        HealthSource live implementation
  Keychain/                         TokenStore live implementation
  UI/                               onboarding, status, settings
Tests/NocturneSyncCoreTests/        Swift Testing, fakes for every protocol
Tests/NocturneSyncIntegrationTests/ against a local Nocturne (manual, not in default scheme)
docs/compat.md                      Nocturne version tested against
```

## Steps

### 0. Scaffolding

- `project.yml` with the app target, bundle id, iOS 18 deployment target, Swift 6 language mode,
  strict concurrency complete, HealthKit + background-delivery entitlements, Info.plist with
  `NSHealthShareUsageDescription` only, `BGTaskSchedulerPermittedIdentifiers`, URL scheme equal to
  the bundle id (OAuth redirect).
- `Package.swift` for `NocturneSyncCore` with a test target. Platforms: iOS 18, macOS 15 (for
  running tests on a Mac without the simulator).
- Empty app that launches. `docs/compat.md` stub. `.gitignore` for `*.xcodeproj`, DerivedData.
- Verify (Mac): `xcodegen generate`, build, `swift test` with zero tests.

### 0b. Cloud toolchain (optional, enables core tests in cloud sessions)

- SessionStart hook that installs a Swift 6 Linux toolchain if missing. Use the
  `session-start-hook` skill. Document in `CLAUDE.md` under Commands.

### 1. Domain and mapping (`Domain/`)

- `HeartRateRecord`, `StepCountRecord`: plain `Sendable` structs matching the Nocturne request
  fields. Constants: `dataSource = "apple-health-ios"`, `stepBucketSeconds = 300`.
- `StepBucket`: epoch-aligned bucket start for any `Date`, `syncIdentifier` formatting, range
  enumeration for a `[start, end)` window.
- `UTCOffsetResolver`: offset in minutes from an optional time zone identifier, else a given
  `TimeZone` at the sample's instant via `secondsFromGMT(for:)`.
- Rounding rule for bpm. Typed `MappingError` for impossible values (negative steps, NaN).
- Tests: bucket alignment across midnight and DST transitions, identifier stability, offset
  resolution at the DST change instant, rounding at .5.

### 2. Nocturne client (`Client/`)

- `HTTPTransport` protocol (`(URLRequest) async throws -> (Data, HTTPURLResponse)`) so the
  client is testable without a network. `URLSessionTransport` live implementation.
- Request DTOs (`Encodable`, ISO 8601 with offset and fractional seconds, camelCase keys).
- `ProblemDetails` decoder. `NocturneClientError`: `badRequest(detail)`, `unauthorized`,
  `forbidden`, `setupRequired`, `recoveryModeActive`, `rateLimited(retryAfter)`,
  `server(status, retryAfter)`, `transport(underlying)`, `decoding`.
- `NocturneClient` protocol: `uploadHeartRates([HeartRateRecord])`,
  `uploadStepCounts([StepCountRecord])`. The live implementation chunks at 500, refuses empty
  input (programmer error, `precondition`), and treats any 2xx as success.
- `FakeNocturneClient`: records calls, scripted responses per call.
- Tests: JSON shape against a golden fixture, chunk boundaries (499/500/501/1000/1001),
  status-to-error mapping, `Retry-After` parsing (seconds and HTTP date).

### 3. Auth (`Auth/`, `Keychain/`)

- `TokenStore` protocol: load/save/clear `TokenSet` (access, refresh, expiry, scope) and the
  cached `client_id` per base URL. `InMemoryTokenStore` fake. `KeychainTokenStore` in the app
  target with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- `PKCE`: verifier and S256 challenge.
- `OAuthClient` over `HTTPTransport`: `register(softwareId, redirectURI, scopes)`,
  `authorizeURL(...)`, `exchange(code, verifier)`, `refresh(refreshToken, clientId)`,
  `revoke(...)`. Decodes OAuth error bodies.
- `AuthSession` actor: owns the token set, `validAccessToken()` with single-flight refresh,
  persists the rotated refresh token before returning the new access token, maps
  `invalid_grant` to `AuthError.signedOut`, never re-registers when a cached `client_id` exists.
- `AuthenticatedTransport`: decorates `HTTPTransport`, adds the bearer header, on 401 refreshes
  once and retries once.
- Tests: N concurrent callers produce exactly one refresh request; persistence happens before
  the access token is handed out (ordering via a recording store); `invalid_grant` clears
  tokens; 401 → refresh → retry → success; 401 → refresh → 401 → `unauthorized` surfaced.
- `ASWebAuthenticationSession` driver lives in the app target (step 9); the core exposes only
  `authorizeURL` and `exchange`.

### 4. Stores (`Stores/`)

- `AnchorStore` protocol: load/save `Data` per data type (the engine archives `HKQueryAnchor`
  itself; the core must not import HealthKit). File-backed implementation with atomic writes and
  `.completeUntilFirstUserAuthentication` (the protection attribute is set only on iOS;
  compiled out elsewhere).
- `SyncStateStore` protocol: `SyncState` struct (per-type `lastSuccessfulSync`, `lastError`,
  `uploadedCount`, step backfill watermark, heart rate backfill done flag). Codable JSON file,
  atomic writes, same protection.
- In-memory fakes for both.
- Tests: round trip, corrupt file yields a typed error and not a crash, atomicity (write to temp
  then rename).

### 5. HealthSource (`Engine/HealthSource.swift`, `HealthKit/`)

- `HealthSource` protocol in the core:
  `heartRateSamples(after: Data?, startingAt: Date, limit: Int) -> HeartRatePage` (samples, anchor,
  `mightHaveMore`),
  `stepTotals(in: DateInterval, bucketSeconds: Int) -> [StepBucketTotal]`,
  `requestReadAuthorization()`, `startObserving(type, onChange)`,
  `enableBackgroundDelivery(type)`. `HealthSourceError.databaseInaccessible` and `.other`.
- `FakeHealthSource` with scripted samples and an injectable error.
- `HealthKitSource` in the app target. Apple behaviour relied on, to be stated in the PR:
  `HKAnchoredObjectQuery` with `limit` returns a new anchor per page; `HKStatisticsCollectionQuery`
  with `.cumulativeSum` applies source prioritisation; `anchorDate` = Unix epoch with a 5 minute
  `DateComponents` interval yields epoch-aligned buckets; `HKError.Code.errorDatabaseInaccessible`
  while locked; observer completion handler must always be called.
- Every anchored heart rate query carries a `startDate >= cutoff` predicate supplied by the engine.
  (Changed from "first query only": anchor order is insertion order, not date order, so a later
  page without the predicate can return old samples inserted late, e.g. a history import.) The
  cutoff is fixed at the first run (decision 7 in `CLAUDE.md`).
- No unit tests possible for the live source. The fake is what the engine tests use.

### 6. SyncEngine and heart rate pipeline (`Engine/`)

- `RetryPolicy`: exponential backoff with full jitter, caps, `Retry-After` honoured, retry only
  on transport errors, 5xx, 429, and the single 401 path (handled in auth). 4xx otherwise fatal
  for the run.
- `SyncEngine` actor: `sync(reason:)` serialises runs (a second request while one is running
  coalesces into one follow-up run), owns all store writes, exposes `SyncState` for the UI.
- The first run persists the heart rate cutoff `now - 90 d` in `SyncState` before querying
  (decision 7); every later run reuses it.
- `HeartRatePipeline`: loop { read page with limit 2000 → map → chunk → upload all chunks →
  commit anchor → record status } until a page is short of the limit. Checks `Task.isCancelled`
  at every chunk boundary; cancellation between chunks does not commit the anchor.
  `databaseInaccessible` ends the run quietly without touching state.
- Tests on fakes: anchor committed only after every chunk succeeded; failure on chunk 3 of 4
  leaves the anchor and re-uploads all 4 next run; cancellation; `databaseInaccessible` leaves
  state untouched and `lastError` nil; retry schedule; counts and timestamps recorded.

### 7. Steps pipeline (`Engine/StepsPipeline.swift`)

- Each run uploads the lookback window `[now - 24 h, now)` first. While the backfill watermark is
  earlier than the lookback start, the run then uploads 1-day slices starting at the watermark
  (oldest first), advancing the watermark after every chunk of a slice succeeded, until caught up
  or cancelled. The first run sets the watermark to `now - 90 d`. (Changed from "one slice per
  run": step triggers arrive at most hourly, so one slice per run would take ~90 runs.)
- Lookback uploads never write state except status; idempotency relies on the server upsert.
- Tests: window and slice computation around DST and month boundaries, watermark advances only
  on success, empty window produces no request, buckets with zero steps are skipped, bucket
  identifiers match step 1.

### 8. Scheduling and launch wiring (`App/`)

Implemented as `AppModel` in the `NocturneSyncFeatures` package target (tested on Linux against
fakes) plus thin glue in the iOS target (`AppDelegate`, `BackgroundRefresh`, `LiveEnvironment`).

- On every launch: request authorization if not yet requested, `enableBackgroundDelivery` for
  both types (`.hourly` for both, decision 9; `.immediate` heart rate would relaunch the app on every
  Watch sync),
  register observer queries whose handler calls `engine.sync(reason: .observer)` and always
  calls the completion handler, including when the sync throws.
- `BGAppRefreshTask` registration as fallback; reschedule after each run; set the task's
  expiration handler to cancel the engine's current run.
- Device-only verification: document the manual checklist in the PR; do not claim it was tested
  on the simulator.

### 9. App UI (`UI/`)

Views in the iOS target bind to `AppModel`; status rows (`DataTypeStatus`), address parsing
(`InstanceURL`) and user messages are in `NocturneSyncFeatures` and tested there.

- Onboarding: base URL entry with validation, "Sign in" launching `ASWebAuthenticationSession`
  with the PKCE URL from `AuthSession`, callback scheme = bundle id.
- Status screen: per type `lastSuccessfulSync`, `lastError.detail`, uploaded count, backfill
  progress, "no data seen yet" when HealthKit returned nothing. "Sync now" button. Sign out.
- Error surfacing per `CLAUDE.md`: scope problem, setup required, recovery mode, signed out.
- No settings for bucket size, lookback, or backfill window; those are fixed.
- `@Observable` view models reading `SyncEngine` state; no Combine.

### 10. Integration tests and docs

- `NocturneSyncIntegrationTests` against `http://localhost:1610`: seed tenant via
  `POST /api/v4/dev-only/admin/seed-tenant`, token via
  `GET /api/v4/dev-only/auth/login?tenant=<slug>&format=json`, upload fixtures (synthetic data
  only), read back via `GET /api/v4/HeartRate?from=&to=`, assert upsert on re-upload. Separate
  scheme, not run by default.
- `docs/compat.md`: Nocturne commit and release tested against, date, any contract deviations.
- README: install, sign in, what "verified on device" means, known gaps (deletions both
  directions, zeroed buckets).

## Cross-cutting rules applied in every step

- `swift format` before commit. Swift Testing only. `os.Logger` with subsystem per module,
  `privacy: .private` on values and tokens. Typed errors per layer, no swallowing `try?`.
- Fakes live next to the protocol they fake, in the test target, and are reused across steps.
- Every PR states which Apple behaviour it relies on and what was verified where.

## Risks to watch

- Background execution budget: an observer-triggered run gets seconds, not minutes. The heart
  rate page limit and the one-day step slice are sized for that; measure on device and shrink if
  runs are killed before the first commit.
- `HKMetadataKeyTimeZone` is rarely present on Watch heart rate samples; the device time zone
  fallback will be the common path. Travel across zones mid-backfill gives historically wrong
  offsets for old samples. Acceptable for a personal app; note in README.
- DCR rate limit (10/h/IP): a sign-in flow that fails after registration must reuse the cached
  `client_id` on retry, never re-register.
- Refresh token 90-day expiry: the status screen must show "signed out" clearly after a long
  idle period.
- Nocturne is pre-1.0. Step 10's integration run against the pinned commit is the regression
  net; re-run it and update `docs/compat.md` whenever the instance is upgraded.
