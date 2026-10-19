/// Nocturne V4 endpoint paths and request limits. Verified against Nocturne `main` at c28fdd6; see
/// `docs/compat.md` before changing anything here.
public enum NocturneAPI {
  public static let heartRatePath = "api/v4/HeartRate"
  public static let stepCountPath = "api/v4/StepCount"
  /// Bulk create-or-update of `SleepSession`s. Answers 201 with the stored sessions.
  public static let sleepSessionsPath = "api/v4/sleep/sessions/bulk"

  /// Server-side hard limit on records per request. The server also answers an empty array with 400.
  public static let maxRecordsPerRequest = 1000

  /// Records the client sends per request. Half the server limit, so a request stays well inside what
  /// a background execution can complete.
  public static let uploadChunkSize = 500

  /// Server-side hard limit on sleep sessions per request, lower than the flat records' because each
  /// session embeds its stage intervals.
  public static let maxSleepSessionsPerRequest = 100

  /// Sleep sessions the client sends per request. A Watch night carries a few hundred stage intervals,
  /// so 20 sessions is a request of the same order as 500 flat records.
  public static let sleepUploadChunkSize = 20
}
