/// Values that are part of the server-side identity of uploaded records. Changing any of them after
/// the first release duplicates history on the server.
public enum NocturneConstants {
  /// Half of Nocturne's dedup key `(dataSource, syncIdentifier)` for heart rate and steps. Fixed forever.
  public static let dataSource = "apple-health-ios"

  /// Half of Nocturne's dedup key `(source, originalId)` for sleep sessions: the `SleepSource` enum
  /// member for Apple Health. Fixed forever.
  public static let sleepSource = "Apple"

  /// Step bucket length. Part of every step `syncIdentifier`, so it is as permanent as `dataSource`.
  public static let stepBucketSeconds = 300

  /// `device` of every step record and sleep session (decision 8). Both are Health's merged view of
  /// iPhone and Watch, so the value names where the data comes from, not a recording device. Not part
  /// of any dedup key.
  public static let mergedDevice = "Apple Health"

  /// Display name; the `app` field of every record is `appIdentifier(version:)`.
  public static let appName = "NocturneSync"

  /// `app` field value: name plus marketing version (Nocturne shows it as `enteredBy`), e.g.
  /// `NocturneSync 0.1.0`. Unlike `dataSource` it is not part of the dedup key and may change freely.
  public static func appIdentifier(version: String) -> String {
    "\(appName) \(version)"
  }
}
