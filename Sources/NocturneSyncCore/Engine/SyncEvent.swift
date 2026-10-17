import Foundation

/// How far one data type has got within the current run, for a progress display.
public struct SyncProgress: Sendable, Equatable {
  public let type: HealthDataType
  /// Records committed in this run so far.
  public var uploaded: Int
  /// Share of this run's work that is done, when it can be known. Steps: backfill slices committed
  /// out of the slices this run has to do. Heart rate: always nil, because HealthKit returns samples
  /// in insertion order, so the amount left is unknown until the last page.
  public var fractionCompleted: Double?
  /// How far the upload has got. Steps: the backfill watermark. Heart rate: the newest sample date
  /// uploaded in this run.
  public var reached: Date?

  public init(type: HealthDataType, uploaded: Int = 0, fractionCompleted: Double? = nil, reached: Date? = nil) {
    self.type = type
    self.uploaded = uploaded
    self.fractionCompleted = fractionCompleted
    self.reached = reached
  }
}

/// What a running sync reports while it works, so the UI can update between commits instead of only
/// after the run. Delivered on `SyncEngine.events`.
public enum SyncEvent: Sendable, Equatable {
  /// The type's pipeline started.
  case started(HealthDataType)
  /// A batch was committed. Carries the run's progress for the type and the state after the commit.
  case progressed(SyncProgress, SyncState)
  /// The type's pipeline ended, however it ended. Its status is in the state from then on.
  case finished(HealthDataType)
}
