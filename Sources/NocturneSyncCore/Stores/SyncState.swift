import Foundation

/// Everything the status screen shows and the engine needs across launches, other than anchors and
/// tokens. Persisted as JSON; field names are a stored format and must only grow.
public struct SyncState: Sendable, Hashable, Codable {
  /// Bumped when a change cannot be read by older code. Files from a newer version are reported as
  /// corrupt rather than misread.
  public static let currentVersion = 1

  /// The last failure of one data type, in the words the status screen shows.
  public struct Failure: Sendable, Hashable, Codable {
    public var message: String
    public var occurredAt: Date

    public init(message: String, occurredAt: Date) {
      self.message = message
      self.occurredAt = occurredAt
    }
  }

  public struct TypeStatus: Sendable, Hashable, Codable {
    /// End of the last run that uploaded (or correctly found nothing) without error.
    public var lastSuccessfulSync: Date?
    /// Cleared by the next successful run.
    public var lastError: Failure?
    /// Records in committed batches since install. Heart rate: counted when the page's anchor is
    /// committed, so a re-upload after an anchor reset counts again. Steps: counted when the backfill
    /// watermark passes the bucket, so each bucket counts once; lookback re-uploads are not counted.
    public var uploadedCount: Int

    public init(lastSuccessfulSync: Date? = nil, lastError: Failure? = nil, uploadedCount: Int = 0) {
      self.lastSuccessfulSync = lastSuccessfulSync
      self.lastError = lastError
      self.uploadedCount = uploadedCount
    }
  }

  public var version: Int
  public var heartRate: TypeStatus
  public var stepCount: TypeStatus
  /// Step buckets older than this have been uploaded by the backfill. `nil` until the first run sets
  /// it to `now - 90 d`; the backfill is complete once it reaches the start of the lookback window.
  public var stepBackfillCompletedThrough: Date?
  /// Set when the heart rate anchored query first returned fewer samples than its limit, i.e. the
  /// 90-day history has been drained once and every later run is incremental.
  public var heartRateBackfillComplete: Bool
  /// Lower bound of every heart rate query, persisted by the first run as `now - 90 d` and never moved
  /// (decision 7). `nil` until that first run.
  public var heartRateBackfillStart: Date?

  public init(
    heartRate: TypeStatus = TypeStatus(),
    stepCount: TypeStatus = TypeStatus(),
    stepBackfillCompletedThrough: Date? = nil,
    heartRateBackfillComplete: Bool = false,
    heartRateBackfillStart: Date? = nil
  ) {
    self.version = Self.currentVersion
    self.heartRate = heartRate
    self.stepCount = stepCount
    self.stepBackfillCompletedThrough = stepBackfillCompletedThrough
    self.heartRateBackfillComplete = heartRateBackfillComplete
    self.heartRateBackfillStart = heartRateBackfillStart
  }

  public subscript(type: HealthDataType) -> TypeStatus {
    get {
      switch type {
      case .heartRate: heartRate
      case .stepCount: stepCount
      }
    }
    set {
      switch type {
      case .heartRate: heartRate = newValue
      case .stepCount: stepCount = newValue
      }
    }
  }
}
