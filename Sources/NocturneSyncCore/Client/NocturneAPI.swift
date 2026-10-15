/// Nocturne V4 endpoint paths and request limits. Verified against Nocturne `main` at 806cb31; see
/// `docs/compat.md` before changing anything here.
public enum NocturneAPI {
  public static let heartRatePath = "api/v4/HeartRate"
  public static let stepCountPath = "api/v4/StepCount"

  /// Server-side hard limit on records per request. The server also answers an empty array with 400.
  public static let maxRecordsPerRequest = 1000

  /// Records the client sends per request. Half the server limit, so a request stays well inside what
  /// a background execution can complete.
  public static let uploadChunkSize = 500
}
