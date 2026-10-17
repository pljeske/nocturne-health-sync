import Foundation
import Testing

@testable import NocturneSyncCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct StepsPipelineTests {
  let pipeline = StepsPipeline(device: "iPhone16,2")
  let now = EngineFixtures.start
  var lookback: DateInterval { StepWindows.lookback(now: now, hours: 24, bucketSeconds: 300) }
  var initialWatermark: Date { StepWindows.initialWatermark(now: now, backfillDays: 90, bucketSeconds: 300) }
  let day: TimeInterval = 86_400

  func harness(
    totals: [StepBucketTotal] = [], client: FakeNocturneClient = FakeNocturneClient(),
    states: InMemorySyncStateStore = InMemorySyncStateStore()
  ) -> EngineHarness {
    EngineHarness(health: FakeHealthSource(stepTotals: totals), client: client, states: states, pipelines: [pipeline])
  }

  func allHistory() -> [StepBucketTotal] {
    EngineFixtures.hourlySteps(from: initialWatermark, to: now)
  }

  @Test func firstRunUploadsTheLookbackThenTheBackfillOldestFirst() async throws {
    let history = allHistory()
    let harness = harness(totals: history)

    let report = await harness.engine.sync(reason: .launch)

    #expect(report.results[.stepCount]?.isCompleted == true)
    let queries = await harness.health.stepQueries
    #expect(queries.first?.interval == lookback)
    let slices = queries.dropFirst().map(\.interval)
    #expect(slices.count == 89)
    #expect(slices.first?.start == initialWatermark)
    #expect(slices.last?.end == lookback.start)
    #expect(slices.allSatisfy { $0.duration == day })
    #expect(zip(slices, slices.dropFirst()).allSatisfy { $0.end == $1.start })
    #expect(queries.allSatisfy { $0.bucketSeconds == 300 })

    let sent = await harness.client.stepCountBatches.flatMap { $0 }.map(\.syncIdentifier)
    #expect(sent.count == history.count)
    #expect(Set(sent) == Set(history.map(\.bucket.syncIdentifier)))

    let state = harness.states.current
    #expect(state.stepBackfillCompletedThrough == lookback.start)
    #expect(state.stepCount.uploadedCount == 89 * 24)
    #expect(state.stepCount.lastSuccessfulSync == now)
    #expect(report.uploaded[.stepCount] == 89 * 24)
  }

  @Test func recordsFollowTheBucketContract() async throws {
    let bucket = StepBucket(containing: now.addingTimeInterval(-3600))
    let harness = harness(totals: [StepBucketTotal(bucket: bucket, steps: 41.5)])
    _ = await harness.engine.sync(reason: .healthChange(.stepCount))
    let record = try #require(await harness.client.stepCountBatches.first?.first)
    #expect(record.syncIdentifier == "steps-\(bucket.startUnixSeconds)-300")
    #expect(record.timestamp == bucket.start)
    #expect(record.metric == 42)
    #expect(record.source == 0)
    #expect(record.device == "iPhone16,2")
    #expect(record.app == "NocturneSync 0.1.0")
    #expect(record.dataSource == "apple-health-ios")
  }

  @Test func zeroAndEmptyBucketsSendNothing() async throws {
    let recent = StepBucket.buckets(overlapping: DateInterval(start: now.addingTimeInterval(-900), end: now))
    let harness = harness(totals: [
      StepBucketTotal(bucket: recent[0], steps: 0), StepBucketTotal(bucket: recent[1], steps: 0.4),
    ])
    let report = await harness.engine.sync(reason: .launch)
    #expect(report.results[.stepCount]?.isCompleted == true)
    #expect(await harness.client.calls.isEmpty)
    #expect(await harness.health.stepQueries.count == 90)
    #expect(harness.states.current.stepBackfillCompletedThrough == lookback.start)
  }

  @Test func incrementalRunCoversTheLookbackAndOnlyTheGap() async throws {
    let harness = harness(totals: allHistory())
    _ = await harness.engine.sync(reason: .launch)
    let firstLookbackStart = lookback.start
    let queriesBefore = await harness.health.stepQueries.count

    harness.clock.advance(by: 3600)
    _ = await harness.engine.sync(reason: .healthChange(.stepCount))

    let later = Array(await harness.health.stepQueries.dropFirst(queriesBefore)).map(\.interval)
    let laterLookback = StepWindows.lookback(now: now.addingTimeInterval(3600), hours: 24, bucketSeconds: 300)
    #expect(later == [laterLookback, DateInterval(start: firstLookbackStart, end: laterLookback.start)])
    #expect(harness.states.current.stepBackfillCompletedThrough == laterLookback.start)
  }

  @Test func unchangedLookbackSendsNothingAndWritesNothing() async throws {
    let recent = EngineFixtures.hourlySteps(from: lookback.start, to: now)
    let harness = harness(totals: recent)
    _ = await harness.engine.sync(reason: .launch)
    let callsAfterFirst = await harness.client.calls.count
    let writesAfterFirst = harness.states.history.count
    #expect(callsAfterFirst == 1)
    #expect(Set(harness.states.current.stepLookbackSent.keys) == Set(recent.map(\.bucket.syncIdentifier)))

    harness.clock.advance(by: 60)  // same window boundary: lookback start is still the same bucket
    _ = await harness.engine.sync(reason: .healthChange(.stepCount))

    // One state write for the status timestamp, no upload, no lookback-map write.
    #expect(await harness.client.calls.count == callsAfterFirst)
    #expect(harness.states.history.count == writesAfterFirst + 1)
    #expect(harness.states.current.stepCount.lastSuccessfulSync == now.addingTimeInterval(60))
  }

  @Test func onlyChangedAndNewBucketsAreSent() async throws {
    let recent = EngineFixtures.hourlySteps(from: lookback.start, to: now)
    let harness = harness(totals: recent)
    _ = await harness.engine.sync(reason: .launch)

    let changed = StepBucketTotal(bucket: recent[3].bucket, steps: 99)
    let added = StepBucketTotal(bucket: StepBucket(containing: now.addingTimeInterval(-600)), steps: 7)
    await harness.health.setStepTotals([changed, added])
    _ = await harness.engine.sync(reason: .healthChange(.stepCount))

    let second = try #require(await harness.client.stepCountBatches.last)
    #expect(Set(second.map(\.syncIdentifier)) == [changed.bucket.syncIdentifier, added.bucket.syncIdentifier])
    #expect(harness.states.current.stepLookbackSent[changed.bucket.syncIdentifier] == 99)
    #expect(harness.states.current.stepLookbackSent[added.bucket.syncIdentifier] == 7)
  }

  @Test func manualSyncResendsTheWholeWindow() async throws {
    let recent = EngineFixtures.hourlySteps(from: lookback.start, to: now)
    let harness = harness(totals: recent)
    _ = await harness.engine.sync(reason: .launch)
    _ = await harness.engine.sync(reason: .manual)
    let batches = await harness.client.stepCountBatches
    #expect(batches.count == 2)
    #expect(batches[1].map(\.syncIdentifier) == batches[0].map(\.syncIdentifier))
  }

  @Test func failedLookbackUploadKeepsTheOldMapSoItIsRetried() async throws {
    let recent = EngineFixtures.hourlySteps(from: lookback.start, to: now)
    let harness = harness(totals: recent)
    _ = await harness.engine.sync(reason: .launch)
    let sentBefore = harness.states.current.stepLookbackSent

    await harness.health.setStepTotals([StepBucketTotal(bucket: recent[0].bucket, steps: 500)])
    let failing = FakeNocturneClient(script: [
      .server(status: 500, retryAfter: nil), .server(status: 500, retryAfter: nil),
      .server(status: 500, retryAfter: nil), .server(status: 500, retryAfter: nil),
    ])
    let retry = EngineHarness(
      health: harness.health, client: failing, states: InMemorySyncStateStore(harness.states.current),
      pipelines: [pipeline])
    _ = await retry.engine.sync(reason: .healthChange(.stepCount))
    #expect(retry.states.current.stepLookbackSent == sentBefore)

    let recovered = EngineHarness(
      health: harness.health, client: FakeNocturneClient(), states: InMemorySyncStateStore(retry.states.current),
      pipelines: [pipeline])
    _ = await recovered.engine.sync(reason: .healthChange(.stepCount))
    let resent = try #require(await recovered.client.stepCountBatches.first)
    #expect(resent.map(\.syncIdentifier) == [recent[0].bucket.syncIdentifier])
    #expect(resent.first?.metric == 500)
  }

  @Test func mapIsPrunedToTheCurrentWindow() async throws {
    let recent = EngineFixtures.hourlySteps(from: lookback.start, to: now)
    let harness = harness(totals: recent)
    _ = await harness.engine.sync(reason: .launch)
    harness.clock.advance(by: 6 * 3600)
    _ = await harness.engine.sync(reason: .healthChange(.stepCount))
    let newLookback = StepWindows.lookback(now: now.addingTimeInterval(6 * 3600), hours: 24, bucketSeconds: 300)
    let kept = harness.states.current.stepLookbackSent.keys
    #expect(
      kept.allSatisfy { id in recent.contains { $0.bucket.syncIdentifier == id && $0.bucket.start >= newLookback.start }
      })
    #expect(kept.count == recent.filter { $0.bucket.start >= newLookback.start }.count)
  }

  @Test func lateWatchSyncReuploadsTheSameBucketWithTheNewTotal() async throws {
    let bucket = StepBucket(containing: now.addingTimeInterval(-7200))
    let harness = harness(totals: [StepBucketTotal(bucket: bucket, steps: 10)])
    _ = await harness.engine.sync(reason: .launch)
    await harness.health.setStepTotals([StepBucketTotal(bucket: bucket, steps: 25)])
    harness.clock.advance(by: 300)
    _ = await harness.engine.sync(reason: .healthChange(.stepCount))

    let uploads = await harness.client.stepCountBatches.flatMap { $0 }.filter {
      $0.syncIdentifier == bucket.syncIdentifier
    }
    #expect(uploads.map(\.metric) == [10, 25])
  }

  @Test func sliceFailureKeepsTheWatermarkAtThatSlice() async throws {
    let client = FakeNocturneClient(script: [nil, nil, .badRequest(ProblemDetails(detail: "bad bucket"))])
    let harness = harness(totals: allHistory(), client: client)

    let first = await harness.engine.sync(reason: .launch)

    #expect(first.results[.stepCount]?.failure != nil)
    #expect(await harness.client.calls.count == 3)
    #expect(harness.states.current.stepBackfillCompletedThrough == initialWatermark.addingTimeInterval(day))
    #expect(harness.states.current.stepCount.uploadedCount == 24)
    #expect(harness.states.current.stepCount.lastError?.message == "bad bucket")

    let queriesBefore = await harness.health.stepQueries.count
    _ = await harness.engine.sync(reason: .launch)
    let resumed = await harness.health.stepQueries.dropFirst(queriesBefore).map(\.interval)
    #expect(resumed.dropFirst().first?.start == initialWatermark.addingTimeInterval(day))
    #expect(harness.states.current.stepBackfillCompletedThrough == lookback.start)
    #expect(harness.states.current.stepCount.lastError == nil)
  }

  @Test func lookbackFailureStopsBeforeTheBackfill() async throws {
    let harness = harness(totals: allHistory(), client: FakeNocturneClient(script: [.forbidden(nil)]))
    let report = await harness.engine.sync(reason: .launch)
    guard case .upload(.forbidden) = report.results[.stepCount]?.failure else {
      Issue.record("expected .forbidden, got \(String(describing: report.results[.stepCount]))")
      return
    }
    #expect(await harness.health.stepQueries.map(\.interval) == [lookback])
    #expect(harness.states.current.stepBackfillCompletedThrough == initialWatermark)
  }

  @Test func cancellationKeepsEveryCommittedSlice() async throws {
    // Cancelled while the third slice's only batch is in flight: that batch succeeds and commits, the
    // fourth slice never starts.
    let client = FakeNocturneClient(onCall: { index in
      if index == 3 { withUnsafeCurrentTask { $0?.cancel() } }
    })
    let harness = harness(totals: allHistory(), client: client)

    let report = await harness.engine.sync(reason: .backgroundRefresh)

    #expect(report.results[.stepCount]?.isCancelled == true)
    #expect(await harness.client.calls.count == 4)
    #expect(harness.states.current.stepBackfillCompletedThrough == initialWatermark.addingTimeInterval(3 * day))
    #expect(harness.states.current.stepCount.uploadedCount == 72)
    #expect(harness.states.current.stepCount.lastSuccessfulSync == nil)
  }

  @Test func lockedDeviceDefersWithoutWrites() async throws {
    let existing = SyncState(stepBackfillCompletedThrough: lookback.start.addingTimeInterval(-day))
    let harness = harness(totals: allHistory(), states: InMemorySyncStateStore(existing))
    await harness.health.failNextStepQueries(.databaseInaccessible)

    let report = await harness.engine.sync(reason: .healthChange(.stepCount))

    #expect(report.results[.stepCount]?.isDeferred == true)
    #expect(harness.states.history.isEmpty)
    #expect(await harness.client.calls.isEmpty)
  }

  @Test func misalignedStatisticsFailWithoutMovingTheWatermark() async throws {
    let harness = harness(totals: allHistory())
    await harness.health.failNextStepQueries(.misalignedStatistics(start: now))
    let report = await harness.engine.sync(reason: .launch)
    guard case .health(.misalignedStatistics) = report.results[.stepCount]?.failure else {
      Issue.record("expected .misalignedStatistics, got \(String(describing: report.results[.stepCount]))")
      return
    }
    #expect(await harness.client.calls.isEmpty)
    #expect(harness.states.current.stepBackfillCompletedThrough == initialWatermark)
  }

  @Test func utcOffsetFollowsDSTInTheDeviceZone() async throws {
    // Berlin leaves CEST (+02:00) at 2024-10-27 01:00 UTC.
    let dstDay = Date(timeIntervalSince1970: 1_729_987_200)  // 2024-10-27 00:00 UTC
    let before = StepBucket(containing: dstDay)
    let after = StepBucket(containing: dstDay.addingTimeInterval(7200))
    let harness = EngineHarness(
      health: FakeHealthSource(stepTotals: [
        StepBucketTotal(bucket: before, steps: 5), StepBucketTotal(bucket: after, steps: 6),
      ]),
      pipelines: [pipeline], start: dstDay.addingTimeInterval(12 * 3600),
      timeZone: TimeZone(identifier: "Europe/Berlin")!)

    _ = await harness.engine.sync(reason: .healthChange(.stepCount))

    let records = await harness.client.stepCountBatches.flatMap { $0 }
    #expect(records.map(\.syncIdentifier) == [before.syncIdentifier, after.syncIdentifier])
    #expect(records.map(\.utcOffsetMinutes) == [120, 60])
  }

  @Test func observerTriggerRunsOnlyStepsLaunchRunsBoth() async throws {
    let harness = EngineHarness(
      health: FakeHealthSource(
        heartRates: EngineFixtures.heartRates(3),
        stepTotals: [StepBucketTotal(bucket: StepBucket(containing: now.addingTimeInterval(-600)), steps: 9)]),
      pipelines: [HeartRatePipeline(), pipeline])

    let launch = await harness.engine.sync(reason: .launch)
    #expect(launch.results[.heartRate]?.isCompleted == true)
    #expect(launch.results[.stepCount]?.isCompleted == true)

    let heartRateQueries = await harness.health.heartRateQueries.count
    let stepsOnly = await harness.engine.sync(reason: .healthChange(.stepCount))
    #expect(stepsOnly.results[.heartRate] == nil)
    #expect(await harness.health.heartRateQueries.count == heartRateQueries)
  }
}
