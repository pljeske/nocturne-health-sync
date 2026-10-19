import Foundation
import NocturneSyncCore
import Testing

@testable import NocturneSyncFeatures

@Suite struct DataTypeStatusTests {
  let now = Date(timeIntervalSince1970: 1_760_000_000)

  func status(_ type: HealthDataType, _ state: SyncState) -> DataTypeStatus {
    DataTypeStatus.make(from: state).first { $0.type == type }!
  }

  @Test func freshInstallHasNothingStarted() {
    let rows = DataTypeStatus.make(from: SyncState())
    #expect(rows.map(\.type) == [.heartRate, .stepCount, .sleep])
    #expect(rows.map(\.title) == ["Heart rate", "Steps", "Sleep"])
    #expect(rows.allSatisfy { $0.backfill == .notStarted && !$0.noDataSeen && $0.lastSuccessfulSync == nil })
  }

  @Test func syncedButNothingUploadedIsNoDataSeen() {
    let row = status(.heartRate, SyncState(heartRate: .init(lastSuccessfulSync: now, uploadedCount: 0)))
    #expect(row.noDataSeen)
    #expect(!status(.heartRate, SyncState(heartRate: .init(lastSuccessfulSync: now, uploadedCount: 3))).noDataSeen)
  }

  @Test func heartRateBackfillStates() {
    #expect(status(.heartRate, SyncState(heartRateBackfillStart: now)).backfill == .inProgress(through: nil))
    #expect(
      status(.heartRate, SyncState(heartRateBackfillComplete: true, heartRateBackfillStart: now)).backfill == .complete)
  }

  @Test func stepBackfillIsCompleteWhenTheWatermarkReachedTheLastRunsLookback() {
    let caughtUp = SyncState(
      stepCount: .init(lastSuccessfulSync: now), stepBackfillCompletedThrough: now.addingTimeInterval(-86_400 - 120))
    #expect(status(.stepCount, caughtUp).backfill == .complete)
  }

  @Test func stepBackfillReportsHowFarItGot() {
    let watermark = now.addingTimeInterval(-40 * 86_400)
    let behind = SyncState(stepCount: .init(lastSuccessfulSync: now), stepBackfillCompletedThrough: watermark)
    #expect(status(.stepCount, behind).backfill == .inProgress(through: watermark))
    let neverCompleted = SyncState(stepBackfillCompletedThrough: watermark)
    #expect(status(.stepCount, neverCompleted).backfill == .inProgress(through: watermark))
  }

  @Test func sleepBackfillIsCompleteWhenTheWatermarkIsWithinTheLookback() {
    let caughtUp = SyncState(
      sleep: .init(lastSuccessfulSync: now), sleepBackfillCompletedThrough: now.addingTimeInterval(-3 * 86_400 + 60))
    #expect(status(.sleep, caughtUp).backfill == .complete)
    let watermark = now.addingTimeInterval(-40 * 86_400)
    let behind = SyncState(sleep: .init(lastSuccessfulSync: now), sleepBackfillCompletedThrough: watermark)
    #expect(status(.sleep, behind).backfill == .inProgress(through: watermark))
    #expect(status(.sleep, SyncState()).backfill == .notStarted)
  }

  @Test func errorIsCarriedThrough() {
    let failure = SyncState.Failure(message: "Nocturne returned HTTP 502.", occurredAt: now)
    #expect(status(.stepCount, SyncState(stepCount: .init(lastError: failure))).lastError == failure)
  }
}
