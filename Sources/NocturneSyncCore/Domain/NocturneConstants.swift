/// Values that are part of the server-side identity of uploaded records. Changing any of them after
/// the first release duplicates history on the server.
public enum NocturneConstants {
  /// Half of Nocturne's dedup key `(dataSource, syncIdentifier)`. Fixed forever.
  public static let dataSource = "apple-health-ios"

  /// Step bucket length. Part of every step `syncIdentifier`, so it is as permanent as `dataSource`.
  public static let stepBucketSeconds = 300

  /// Display name; the `app` field of every record is `appIdentifier(version:)`.
  public static let appName = "NocturneSync"

  /// `app` field value: name plus marketing version (Nocturne shows it as `enteredBy`), e.g.
  /// `NocturneSync 0.1.0`. Unlike `dataSource` it is not part of the dedup key and may change freely.
  public static func appIdentifier(version: String) -> String {
    "\(appName) \(version)"
  }
}
