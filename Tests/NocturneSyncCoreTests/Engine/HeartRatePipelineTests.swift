import Foundation
import Testing

@testable import NocturneSyncCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct HeartRatePipelineTests {
  let cutoff = EngineFixtures.start.addingTimeInterval(-90 * 86_400)

  @Test func backfillPagesUploadsInChunksAndCommitsPerPage() async throws {
    let samples = EngineFixtures.heartRates(5000)
    let harness = EngineHarness(health: FakeHealthSource(heartRates: samples))

    let report = await harness.engine.sync(reason: .launch)

    #expect(report.results[.heartRate]?.isCompleted == true)
    #expect(report.uploaded[.heartRate] == 5000)
    #expect(await harness.client.heartRateBatches.map(\.count) == [500, 500, 500, 500, 500, 500, 500, 500, 500, 500])
    #expect(await harness.client.heartRateBatches.flatMap { $0 }.map(\.syncIdentifier) == samples.map(\.id.uuidString))
    #expect(harness.anchors.saves.map(\.1) == [2000, 4000, 5000].map { FakeHealthSource.anchor(position: $0) })
    #expect(await harness.health.heartRateQueries.map(\.limit) == [2000, 2000, 2000])
    #expect(await harness.health.heartRateQueries.allSatisfy { $0.start == cutoff })

    let state = harness.states.current
    #expect(state.heartRate.uploadedCount == 5000)
    #expect(state.heartRate.lastSuccessfulSync == EngineFixtures.start)
    #expect(state.heartRate.lastError == nil)
    #expect(state.heartRateBackfillComplete)
    #expect(state.heartRateBackfillStart == cutoff)
  }

  @Test func recordsAreMappedWithDeviceTimeZoneFallback() async throws {
    let harness = EngineHarness(health: FakeHealthSource(heartRates: EngineFixtures.heartRates(1)))
    _ = await harness.engine.sync(reason: .manual)
    let record = try #require(await harness.client.heartRateBatches.first?.first)
    #expect(record.utcOffsetMinutes == 0)
    #expect(record.bpm == 60)
    #expect(record.device == "Watch7,1")
    #expect(record.app == "NocturneSync 0.1.0")
  }

  @Test func cutoffIsPersistedBeforeTheFirstQueryAndNeverMoves() async throws {
    let harness = EngineHarness(health: FakeHealthSource(heartRates: EngineFixtures.heartRates(3)))
    await harness.health.failNextHeartRateQueries(.databaseInaccessible)

    let locked = await harness.engine.sync(reason: .launch)
    #expect(locked.results[.heartRate]?.isDeferred == true)
    #expect(harness.states.current.heartRateBackfillStart == cutoff)

    harness.clock.advance(by: 30 * 86_400)
    await harness.health.appendHeartRates(EngineFixtures.heartRates(2, from: 3))
    _ = await harness.engine.sync(reason: .launch)
    harness.clock.advance(by: 100 * 86_400)
    _ = await harness.engine.sync(reason: .launch)

    #expect(await harness.health.heartRateQueries.map(\.start) == [cutoff, cutoff, cutoff])
    #expect(harness.states.current.heartRateBackfillStart == cutoff)
  }

  @Test func incrementalRunResumesFromTheCommittedAnchor() async throws {
    let harness = EngineHarness(health: FakeHealthSource(heartRates: EngineFixtures.heartRates(10)))
    _ = await harness.engine.sync(reason: .launch)
    await harness.health.appendHeartRates(EngineFixtures.heartRates(3, from: 10))
    let second = await harness.engine.sync(reason: .healthChange(.heartRate))

    #expect(second.uploaded[.heartRate] == 3)
    #expect(await harness.client.heartRateBatches.map(\.count) == [10, 3])
    #expect(await harness.health.heartRateQueries.map(\.anchor) == [nil, FakeHealthSource.anchor(position: 10)])
    #expect(harness.states.current.heartRate.uploadedCount == 13)
  }

  @Test func nothingNewMeansNoUploadButAFreshTimestamp() async throws {
    let harness = EngineHarness(health: FakeHealthSource())
    let report = await harness.engine.sync(reason: .launch)
    #expect(report.results[.heartRate]?.isCompleted == true)
    #expect(await harness.client.calls.isEmpty)
    #expect(harness.anchors.saves.count == 1)
    #expect(harness.states.current.heartRate.lastSuccessfulSync == EngineFixtures.start)
    #expect(harness.states.current.heartRateBackfillComplete)
  }

  @Test func cancellationAfterThePageLastChunkStillCommitsIt() async throws {
    // Every chunk of the page got a 2xx; committing is correct even though the task is now cancelled.
    let client = FakeNocturneClient(onCall: { index in
      if index == 1 { withUnsafeCurrentTask { $0?.cancel() } }
    })
    let harness = EngineHarness(health: FakeHealthSource(heartRates: EngineFixtures.heartRates(800)), client: client)
    let report = await harness.engine.sync(reason: .backgroundRefresh)
    #expect(report.uploaded[.heartRate] == 800)
    #expect(harness.anchors.saves.map(\.1) == [FakeHealthSource.anchor(position: 800)])
  }

  @Test func failureOnChunkThreeOfFourKeepsTheAnchorAndResendsTheWholePage() async throws {
    let samples = EngineFixtures.heartRates(1999)
    let harness = EngineHarness(
      health: FakeHealthSource(heartRates: samples),
      client: FakeNocturneClient(script: [
        nil, nil, .badRequest(ProblemDetails(detail: "HeartRate at index 3 is invalid")),
      ]))

    let first = await harness.engine.sync(reason: .launch)

    #expect(first.results[.heartRate]?.failure != nil)
    #expect(first.uploaded[.heartRate] == 0)
    #expect(await harness.client.heartRateBatches.map(\.count) == [500, 500, 500])
    #expect(harness.anchors.saves.isEmpty)
    #expect(harness.states.current.heartRate.lastError?.message == "HeartRate at index 3 is invalid")
    #expect(harness.states.current.heartRate.lastSuccessfulSync == nil)
    #expect(harness.states.current.heartRate.uploadedCount == 0)

    harness.clock.advance(by: 60)
    let second = await harness.engine.sync(reason: .launch)

    #expect(second.results[.heartRate]?.isCompleted == true)
    let batches = await harness.client.heartRateBatches
    #expect(batches.map(\.count) == [500, 500, 500, 500, 500, 500, 499])
    #expect(batches.dropFirst(3).flatMap { $0 }.map(\.syncIdentifier) == samples.map(\.id.uuidString))
    #expect(harness.anchors.saves.count == 1)
    #expect(harness.states.current.heartRate.lastError == nil)
    #expect(harness.states.current.heartRate.lastSuccessfulSync == EngineFixtures.start.addingTimeInterval(60))
    #expect(harness.states.current.heartRate.uploadedCount == 1999)
  }

  @Test func cancellationBetweenChunksCommitsNothingOfThatPage() async throws {
    // Two pages (2000 + 1000 samples, 4 + 2 chunks). The first commits; the run is cancelled while the
    // second page's first chunk is in flight, so its second chunk is never sent.
    let client = FakeNocturneClient(onCall: { index in
      if index == 4 { withUnsafeCurrentTask { $0?.cancel() } }
    })
    let harness = EngineHarness(health: FakeHealthSource(heartRates: EngineFixtures.heartRates(3000)), client: client)

    let report = await harness.engine.sync(reason: .backgroundRefresh)

    #expect(report.results[.heartRate]?.isCancelled == true)
    #expect(report.uploaded[.heartRate] == 2000)
    #expect(await harness.client.calls.count == 5)
    #expect(harness.anchors.saves.map(\.1) == [FakeHealthSource.anchor(position: 2000)])
    let state = harness.states.current
    #expect(state.heartRate.uploadedCount == 2000)
    #expect(state.heartRate.lastError == nil)
    #expect(state.heartRate.lastSuccessfulSync == nil)
    #expect(!state.heartRateBackfillComplete)
  }

  @Test func lockedDeviceLeavesStateUntouched() async throws {
    let existing = SyncState(
      heartRate: .init(lastSuccessfulSync: EngineFixtures.start.addingTimeInterval(-3600), uploadedCount: 7),
      heartRateBackfillStart: cutoff)
    let harness = EngineHarness(
      health: FakeHealthSource(heartRates: EngineFixtures.heartRates(5)), states: InMemorySyncStateStore(existing))
    await harness.health.failNextHeartRateQueries(.databaseInaccessible)

    let report = await harness.engine.sync(reason: .healthChange(.heartRate))

    #expect(report.results[.heartRate]?.isDeferred == true)
    #expect(harness.states.history.isEmpty)
    #expect(harness.anchors.saves.isEmpty)
    #expect(await harness.client.calls.isEmpty)
    #expect(harness.states.current == existing)
  }

  @Test func transientFailuresAreRetriedWithBackoff() async throws {
    let harness = EngineHarness(
      health: FakeHealthSource(heartRates: EngineFixtures.heartRates(10)),
      client: FakeNocturneClient(script: [.server(status: 503, retryAfter: nil), .transport(URLError(.timedOut))]))

    let report = await harness.engine.sync(reason: .manual)

    #expect(report.results[.heartRate]?.isCompleted == true)
    #expect(await harness.client.calls.count == 3)
    #expect(harness.sleeps.delays == [0.5, 1.0])
    #expect(harness.anchors.saves.count == 1)
  }

  @Test func retriesStopAtMaxAttempts() async throws {
    let error = NocturneClientError.server(status: 500, retryAfter: nil)
    let harness = EngineHarness(
      health: FakeHealthSource(heartRates: EngineFixtures.heartRates(10)),
      client: FakeNocturneClient(script: [error, error, error, error]))

    let report = await harness.engine.sync(reason: .manual)

    guard case .upload(.server(status: 500, retryAfter: nil)) = report.results[.heartRate]?.failure else {
      Issue.record("expected a server failure, got \(String(describing: report.results[.heartRate]))")
      return
    }
    #expect(await harness.client.calls.count == 4)
    #expect(harness.sleeps.delays == [0.5, 1.0, 2.0])
    #expect(harness.anchors.saves.isEmpty)
    #expect(
      harness.states.current.heartRate.lastError?.message == "Nocturne returned HTTP 500. Syncing will resume later.")
  }

  @Test func longRetryAfterEndsTheRunWithoutSleeping() async throws {
    let harness = EngineHarness(
      health: FakeHealthSource(heartRates: EngineFixtures.heartRates(10)),
      client: FakeNocturneClient(script: [.rateLimited(retryAfter: 600)]))
    let report = await harness.engine.sync(reason: .manual)
    #expect(report.results[.heartRate]?.failure != nil)
    #expect(harness.sleeps.delays.isEmpty)
    #expect(await harness.client.calls.count == 1)
  }

  @Test func forbiddenIsNotRetried() async throws {
    let harness = EngineHarness(
      health: FakeHealthSource(heartRates: EngineFixtures.heartRates(10)),
      client: FakeNocturneClient(script: [.forbidden(nil)]))
    let report = await harness.engine.sync(reason: .manual)
    guard case .upload(.forbidden) = report.results[.heartRate]?.failure else {
      Issue.record("expected .forbidden, got \(String(describing: report.results[.heartRate]))")
      return
    }
    #expect(await harness.client.calls.count == 1)
    #expect(harness.sleeps.delays.isEmpty)
  }

  @Test func unreadableAnchorIsDroppedAndTheBackfillRestarts() async throws {
    let anchors = InMemoryAnchorStore(anchors: [.heartRate: Data("from an older build".utf8)])
    let harness = EngineHarness(health: FakeHealthSource(heartRates: EngineFixtures.heartRates(4)), anchors: anchors)

    let report = await harness.engine.sync(reason: .launch)

    #expect(report.results[.heartRate]?.isCompleted == true)
    #expect(await harness.health.heartRateQueries.map(\.anchor) == [Data("from an older build".utf8), nil])
    #expect(await harness.client.heartRateBatches.map(\.count) == [4])
    #expect(harness.anchors.anchors[.heartRate] == FakeHealthSource.anchor(position: 4))
  }

  @Test func unmappableSampleIsSkippedNotFatal() async throws {
    var samples = EngineFixtures.heartRates(5)
    samples[2].beatsPerMinute = .nan
    let harness = EngineHarness(health: FakeHealthSource(heartRates: samples))

    let report = await harness.engine.sync(reason: .launch)

    #expect(report.results[.heartRate]?.isCompleted == true)
    #expect(
      await harness.client.heartRateBatches.flatMap { $0 }.map(\.syncIdentifier)
        == [0, 1, 3, 4].map { samples[$0].id.uuidString })
    #expect(harness.anchors.anchors[.heartRate] == FakeHealthSource.anchor(position: 5))
    #expect(harness.states.current.heartRate.uploadedCount == 4)
  }

  @Test func signedOutStopsWithAClearMessage() async throws {
    let harness = EngineHarness(
      health: FakeHealthSource(heartRates: EngineFixtures.heartRates(10)),
      client: FakeNocturneClient(script: [.auth(.signedOut)]))
    let report = await harness.engine.sync(reason: .launch)
    #expect(report.results[.heartRate]?.failure?.stopsRun == true)
    #expect(harness.states.current.heartRate.lastError?.message == "Signed out. Sign in again to resume syncing.")
    #expect(harness.sleeps.delays.isEmpty)
  }
}
