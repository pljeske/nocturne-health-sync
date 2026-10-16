# NocturneSync

An iPhone app that reads heart rate and step count from Apple Health and uploads them to your own
[Nocturne](https://github.com/nightscout/nocturne) instance. Single user, personal use. It only
reads Health, never writes to it, and sends nothing anywhere except your instance: no analytics, no
crash reporting, no third-party SDKs.

Not a medical device. The app shows what was synced and when, never the values themselves.

## What it uploads

| Health data | Nocturne endpoint | How |
| --- | --- | --- |
| Heart rate | `POST /api/v4/HeartRate` | Every sample, as recorded (workouts included, no downsampling). |
| Step count | `POST /api/v4/StepCount` | Health's own total per 5-minute bucket, so iPhone and Watch steps are not counted twice. |

The first sync uploads the last 90 days, oldest steps first. After that, new data is uploaded as
iOS delivers it: heart rate usually within minutes, steps at most hourly (an iOS limit). Each run
also re-sends the last 24 hours of step buckets to pick up late Watch syncs. Every record carries a
stable identifier, so re-sending never creates duplicates on the server.

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
   `heartrate.readwrite` and `stepcount.readwrite` access it asks for; it asks for nothing else.
2. Allow read access to Heart Rate and Steps when iOS asks.
3. The status screen shows, per data type, the last successful sync, how many records were uploaded,
   how far the history upload has got, and the last error, if any. **Sync now** (or pull to refresh)
   syncs immediately.

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
- **Time zones while travelling.** Heart rate samples rarely carry their own time zone, so local
  time comes from the phone's current time zone. History uploaded after crossing zones is labelled
  with the new zone.
- **Background timing is up to iOS.** Delivery can be delayed or throttled, especially in Low Power
  Mode or with Background App Refresh off. Opening the app always syncs.

## Verified where

| What | Where it is verified |
| --- | --- |
| Mapping, chunking, retry, auth refresh, sync engine, both pipelines, app model | Unit tests (`swift test`, macOS and Linux) |
| Request shapes, upsert by `syncIdentifier`, auth errors against a real server | Integration tests against a local development Nocturne (`docs/integration.md`) |
| HealthKit queries, Keychain, sign-in sheet, SwiftUI | iOS simulator and device |
| Background delivery, BG refresh, locked-device behaviour | Device only. The simulator does not deliver Health updates in the background. |

"Verified on device" means the checklist below was run on a physical iPhone; nothing else counts.

### Device checklist

1. Fresh install, sign in, allow Health access: both types show a recent sync; heart rate history
   catches up within a few foreground runs.
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
