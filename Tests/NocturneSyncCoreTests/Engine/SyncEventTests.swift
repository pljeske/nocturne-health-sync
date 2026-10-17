import Foundation
import Testing

@testable import NocturneSyncCore

/// Reads buffered events until `type` reports finished. Call after the run, so everything is buffered.
func events(from engine: SyncEngine, until type: HealthDataType) async -> [SyncEvent] {
  var collected: [SyncEvent] = []
  for await event in engine.events {
    collected.append(event)
    if event == .finished(type) { break }
  }
  return collected
}

extension SyncEvent {
  var progress: SyncProgress? { if case .progressed(let progress, _) = self { progress } else { nil } }
  var state: SyncState? { if case .progressed(_, let state) = self { state } else { nil } }
}

@Suite struct SyncEventTests {
  let now = EngineFixtures.start

  @Test func heartRateReportsEachCommittedPage() async throws {
    let samples = EngineFixtures.heartRates(5000)
    let harness = EngineHarness(health: FakeHealthSource(heartRates: samples))
    _ = await harness.engine.sync(reason: .launch)

    let received = await events(from: harness.engine, until: .heartRate)

    #expect(received.first == .started(.heartRate))
    #expect(received.last == .finished(.heartRate))
    let progress = received.compactMap(\.progress)
    #expect(progress.map(\.uploaded) == [2000, 4000, 5000])
    #expect(progress.allSatisfy { $0.type == .heartRate && $0.fractionCompleted == nil })
    #expect(progress.map(\.reached) == [1999, 3999, 4999].map { samples[$0].date })
    // Each event carries the state right after its commit, so counts move while the run is going.
    #expect(received.compactMap(\.state).map(\.heartRate.uploadedCount) == [2000, 4000, 5000])
  }

  @Test func stepsReportExactFractionsPerSlice() async throws {
    let pipeline = StepsPipeline(device: "Apple Health", backfillDays: 5)
    let watermark = StepWindows.initialWatermark(now: now, backfillDays: 5, bucketSeconds: 300)
    let lookback = StepWindows.lookback(now: now, hours: 24, bucketSeconds: 300)
    let harness = EngineHarness(
      health: FakeHealthSource(stepTotals: EngineFixtures.hourlySteps(from: watermark, to: now)),
      pipelines: [pipeline])
    _ = await harness.engine.sync(reason: .launch)

    let received = await events(from: harness.engine, until: .stepCount)

    #expect(received.first == .started(.stepCount))
    #expect(received.last == .finished(.stepCount))
    let progress = received.compactMap(\.progress)
    #expect(progress.map(\.fractionCompleted) == [0.25, 0.5, 0.75, 1.0])
    #expect(progress.map(\.uploaded) == [24, 48, 72, 96])
    #expect(progress.map(\.reached) == (1...4).map { watermark.addingTimeInterval(TimeInterval($0) * 86_400) })
    #expect(progress.last?.reached == lookback.start)
  }

  @Test func longBackfillDeliversTheNewestProgress() async throws {
    // 89 slices produce more events than the buffer holds; the newest survive.
    let watermark = StepWindows.initialWatermark(now: now, backfillDays: 90, bucketSeconds: 300)
    let harness = EngineHarness(
      health: FakeHealthSource(stepTotals: EngineFixtures.hourlySteps(from: watermark, to: now)),
      pipelines: [StepsPipeline(device: "Apple Health")])
    _ = await harness.engine.sync(reason: .launch)

    let received = await events(from: harness.engine, until: .stepCount)
    let fractions = received.compactMap(\.progress).compactMap(\.fractionCompleted)

    #expect(received.count == 64)
    #expect(fractions.last == 1.0)
    #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 < $1 })
  }

  @Test func failedRunStillReportsFinishedWithoutProgress() async throws {
    let harness = EngineHarness(
      health: FakeHealthSource(heartRates: EngineFixtures.heartRates(10)),
      client: FakeNocturneClient(script: [.forbidden(nil)]))
    _ = await harness.engine.sync(reason: .manual)
    #expect(await events(from: harness.engine, until: .heartRate) == [.started(.heartRate), .finished(.heartRate)])
  }

  @Test func eachTypeOfARunIsBracketed() async throws {
    let harness = EngineHarness(
      health: FakeHealthSource(
        heartRates: EngineFixtures.heartRates(3),
        stepTotals: [StepBucketTotal(bucket: StepBucket(containing: now.addingTimeInterval(-600)), steps: 9)]),
      pipelines: [HeartRatePipeline(), StepsPipeline(device: "Apple Health", backfillDays: 1)])
    _ = await harness.engine.sync(reason: .launch)

    let kinds = await events(from: harness.engine, until: .stepCount).map { event -> String in
      switch event {
      case .started(let type): "start \(type.rawValue)"
      case .progressed(let progress, _): "progress \(progress.type.rawValue)"
      case .finished(let type): "finish \(type.rawValue)"
      }
    }
    #expect(kinds.first == "start heartRate")
    #expect(kinds.firstIndex(of: "finish heartRate")! < kinds.firstIndex(of: "start stepCount")!)
    #expect(kinds.last == "finish stepCount")
  }
}
