/// Values that are part of the server-side identity of uploaded records. Changing any of them after
/// the first release duplicates history on the server.
public enum NocturneConstants {
  /// Half of Nocturne's dedup key `(dataSource, syncIdentifier)`. Fixed forever.
  public static let dataSource = "apple-health-ios"

  /// Step bucket length. Part of every step `syncIdentifier`, so it is as permanent as `dataSource`.
  public static let stepBucketSeconds = 300

  /// Reported in the `app` field of every record.
  public static let appName = "NocturneSync"
}
