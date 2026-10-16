import Foundation
import NocturneSyncCore

/// One row of the status screen. Descriptive only: it reports what was synced, never interprets the
/// values (this is not a medical device).
public struct DataTypeStatus: Sendable, Equatable, Identifiable {
  public enum Backfill: Sendable, Equatable {
    case notStarted
    /// Steps report how far back history is uploaded; heart rate cannot (anchor order is not date
    /// order), so `through` is nil.
    case inProgress(through: Date?)
    case complete
  }

  public var id: HealthDataType { type }
  public let type: HealthDataType
  public let title: String
  public let lastSuccessfulSync: Date?
  public let uploadedCount: Int
  public let lastError: SyncState.Failure?
  public let backfill: Backfill
  /// Synced successfully but never uploaded anything. Health may hold no such data, or read access
  /// was denied; HealthKit makes the two indistinguishable, so the UI must not guess which.
  public let noDataSeen: Bool

  public static func make(from state: SyncState) -> [DataTypeStatus] {
    HealthDataType.allCases.map { type in
      let status = state[type]
      return DataTypeStatus(
        type: type,
        title: title(for: type),
        lastSuccessfulSync: status.lastSuccessfulSync,
        uploadedCount: status.uploadedCount,
        lastError: status.lastError,
        backfill: backfill(for: type, in: state),
        noDataSeen: status.lastSuccessfulSync != nil && status.uploadedCount == 0)
    }
  }

  static func title(for type: HealthDataType) -> String {
    switch type {
    case .heartRate: "Heart rate"
    case .stepCount: "Steps"
    }
  }

  static func backfill(for type: HealthDataType, in state: SyncState) -> Backfill {
    switch type {
    case .heartRate:
      if state.heartRateBackfillComplete { return .complete }
      return state.heartRateBackfillStart == nil ? .notStarted : .inProgress(through: nil)
    case .stepCount:
      guard let watermark = state.stepBackfillCompletedThrough else { return .notStarted }
      // A successful run leaves the watermark at its lookback start, 24 h before the run began. An
      // hour of slack covers the run's own duration.
      if let last = state.stepCount.lastSuccessfulSync, last.timeIntervalSince(watermark) <= 25 * 3600 {
        return .complete
      }
      return .inProgress(through: watermark)
    }
  }
}
