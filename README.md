# NocturneSync

An iPhone app that reads heart rate, step count and sleep from Apple Health and uploads them to your own
[Nocturne](https://github.com/nightscout/nocturne) instance. Single user, personal use. It only
reads Health, never writes to it, and sends nothing anywhere except your instance: no analytics, no
crash reporting, no third-party SDKs.

Not a medical device. The app shows what was synced and when, never the values themselves.

## What it uploads

| Health data | Nocturne endpoint | How |
| --- | --- | --- |
| Heart rate | `POST /api/v4/HeartRate` | Every sample, as recorded (workouts included, no downsampling). |
| Step count | `POST /api/v4/StepCount` | Health's own total per 5-minute bucket, so iPhone and Watch steps are not counted twice. |
| Sleep | `POST /api/v4/sleep/sessions/bulk` | One session per night or nap, with every stage interval Health has (Watch stages, iPhone "in bed"). |

The first sync uploads the last 90 days, oldest steps and nights first. After that, new data is
uploaded as iOS delivers it, about hourly. Each run re-checks the last 24 hours of step buckets and
the last three sleep days (noon to noon) and re-sends only what changed, which picks up late Watch
syncs and edits in Health; **Sync now** re-sends those windows whole. Every record carries a stable
identifier, so re-sending never creates duplicates on the server.

The app is built to stay light: it wakes about once an hour when new data exists, does nothing
when nothing changed (no request, no disk write), and keeps no timers or connections open.

## Requirements

- iPhone on iOS 18 or later, with Health data (an Apple Watch for heart rate).
- A Nocturne instance reachable over https (tested contract: see `docs/compat.md`).
- To build: a Mac with Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Build and install

```sh
export DEVELOPMENT_TEAM=<your team id>   # device builds only
xcodegen generate                        # the .xcodeproj is generated, never committed
open NocturneSync.xcodeproj
```

Run the `NocturneSync` scheme on your iPhone. The bundle id is `com.pljeske.NocturneSync`; change
`bundleIdPrefix` in `project.yml` if you sign with your own team. The OAuth redirect scheme follows
the bundle id automatically.

## Use

1. Enter your instance address (e.g. `https://you.nocturne.example`) and tap **Sign in**. NocturneSync
   registers itself with your instance and opens its sign-in page. Approve the
   `heartrate.readwrite`, `stepcount.readwrite` and `sleep.readwrite` access it asks for; it asks for
   nothing else. (Signed in before sleep was added? Sign out and in again to grant the new scope;
   until then the sleep row shows "denied access".)
2. Allow read access to Heart Rate, Steps and Sleep when iOS asks.
3. The status screen shows, per data type, the last successful sync, how many records were uploaded,
   how far the history upload has got, and the last error, if any. **Sync now** (or pull to refresh)
   syncs immediately and re-sends the whole last day of steps.
   While a sync runs, **Syncing now** shows live progress per data type, updated after every
   uploaded batch: a progress bar for steps and sleep, and for heart rate a running count with the
   newest record reached (HealthKit gives no total for heart rate, so there is no percentage).

"No data seen yet" means a sync succeeded but found nothing to upload. Health does not tell apps
whether read access was denied, so this can mean either no data or no access; check
Settings › Health › Data Access & Devices › NocturneSync.

A sign-in lasts as long as the app syncs at least every 90 days. After a longer pause, sign in again.

## Known gaps

- **Deletions are not propagated.** Deleting a sample in Health does not delete it in Nocturne.
- **Deletions in Nocturne do not stick.** A record you delete in Nocturne is uploaded again by the
  next sync that covers it (for steps, within 24 hours; heart rate only after the app's saved
  position is reset).
- **Steps are never zeroed.** A 5-minute bucket that once had steps and later drops to zero in Health
  keeps its last non-zero total on the server.
- **Sleep sessions are named by position.** Health has no session objects, so the app groups sleep
  samples into sessions (a gap of more than an hour starts a new one) and names each by its sleep
  day (local noon to noon) and position within it. Late data and edits update a session in place; a
  day that ends up with fewer sessions than it once had (one deleted in Health, two merged) leaves
  the last one orphaned on the server. Delete it in Nocturne; the app will not recreate it. Changing
  time zones shifts the day boundaries, which can rename sessions near noon.
- **Sleep from iPhone only is "in bed".** Without a Watch (or another stage source), Health records
  only in-bed time, which Nocturne stores as a session with zero sleep, as Health shows it.
- **Time zones while travelling.** Heart rate samples rarely carry their own time zone, so local
  time comes from the phone's current time zone. History uploaded after crossing zones is labelled
  with the new zone.
- **Background timing is up to iOS.** Delivery can be delayed or throttled, especially in Low Power
  Mode or with Background App Refresh off. Opening the app always syncs.

## Verified where

| What | Where it is verified |
| --- | --- |
| Mapping, chunking, retry, auth refresh, sync engine, all three pipelines, app model | Unit tests (`swift test`, macOS and Linux) |
| Request shapes, upsert by `syncIdentifier`, auth errors against a real server | Integration tests against a local development Nocturne (`docs/integration.md`) |
| HealthKit queries, Keychain, sign-in sheet, SwiftUI | iOS simulator and device |
| Background delivery, BG refresh, locked-device behaviour | Device only. The simulator does not deliver Health updates in the background. |

"Verified on device" means the checklist below was run on a physical iPhone; nothing else counts.

### Device checklist

1. Fresh install, sign in, allow Health access: all three types show a recent sync; heart rate
   history catches up within a few foreground runs.
1. Sleep with the Watch, wake up: the night appears in Nocturne as one session with stages after
   the next sync; a nap the same afternoon appears as a second session without renaming the night.
2. Lock the phone, wear the Watch for 30 minutes: heart rate arrives in Nocturne without opening the
   app.
3. Reboot, do not unlock, wait: no errors are recorded (Health is locked); after unlocking, syncing
   resumes.
4. Revoke the grant in Nocturne: the next sync shows "Signed out" and syncing stops.
5. Airplane mode, Sync now: a network error is shown; turning it off and syncing clears it.

## Development

```sh
swift build && swift test                                   # core + features, offline
swift format lint --strict --recursive Sources Tests Package.swift
```

| Path | Contents | Builds on Linux |
| --- | --- | --- |
| `Sources/NocturneSyncCore` | Records and mapping, Nocturne client, OAuth/PKCE, stores, sync engine, pipelines | Yes |
| `Sources/NocturneSyncFeatures` | `AppModel` (launch, sign-in, observers, sync, sign-out), status rows | Yes |
| `Sources/NocturneSync` | iOS glue: HealthKit, Keychain, BackgroundTasks, sign-in sheet, SwiftUI | No (Xcode) |

`CLAUDE.md` holds the design rules and decisions; `docs/plan.md` the implementation plan;
`docs/compat.md` the Nocturne versions verified against.
