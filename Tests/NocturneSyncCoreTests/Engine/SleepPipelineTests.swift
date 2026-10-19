import Foundation
import Testing

@testable import NocturneSyncCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct SleepPipelineTests {
  let pipeline = SleepPipeline(device: "Apple Health")
  let utc = EngineFixtures.utc
  /// 2025-10-09 08:53:20 UTC. Its sleep day starts 2025-10-08 12:00 UTC.
  let now = EngineFixtures.start
  let day: TimeInterval = 86_400
  var today: Date { SleepDays.dayStart(containing: now, in: utc) }
  var lookbackStart: Date { today.addingTimeInterval(-2 * day) }
  var initialWatermark: Date { SleepDays.dayStart(containing: now.addingTimeInterval(-90 * day), in: utc) }

  func harness(
    sleep: [SleepSample] = [], biometrics: [BiometricSample] = [], client: FakeNocturneClient = FakeNocturneClient(),
    states: InMemorySyncStateStore = InMemorySyncStateStore()
  ) -> EngineHarness {
    EngineHarness(
      health: FakeHealthSource(sleep: sleep, biometrics: biometrics), client: client, states: states,
      pipelines: [pipeline])
  }

  /// A night per sleep day from `from` (a day start) up to the day containing `to`, bedtime at 22:00.
  func nights(from: Date, to: Date) -> [SleepSample] {
    var samples: [SleepSample] = []
    var dayStart = from
    while dayStart < to {
      samples += EngineFixtures.night(from: dayStart.addingTimeInterval(10 * 3600))
      dayStart = SleepDays.dayStart(dayStart, offsetBy: 1, in: utc)
    }
    return samples
  }

  @Test func firstRunUploadsTheLookbackThenTheBackfillOneDayAtATime() async throws {
    // The last night (bedtime yesterday 22:00) ends 06:00 today, before `now`.
    let history = nights(from: initialWatermark, to: now)
    let harness = harness(sleep: history)

    let report = await harness.engine.sync(reason: .launch)

    #expect(report.results[.sleep]?.isCompleted == true)
    let queries = await harness.health.sleepQueries
    #expect(queries.first == DateInterval(start: lookbackStart - day, end: now + day))
    let slices = queries.dropFirst()
    #expect(slices.count == 88)
    #expect(slices.first?.start == initialWatermark - day)
    #expect(slices.last?.end == lookbackStart + day)
    #expect(slices.allSatisfy { $0.duration == 3 * day })

    let sent = await harness.client.sleepBatches.flatMap { $0 }
    #expect(sent.count == 91)
    #expect(Set(sent.map(\.originalID)).count == 91)
    #expect(sent.allSatisfy { $0.originalID.hasSuffix("-0") && $0.kind == .overnight && $0.stages.count == 17 })
    // Lookback first (three sessions, newest days), then the backfill oldest first.
    #expect(sent.prefix(3).map(\.originalID) == ["sleep-2025-10-06-0", "sleep-2025-10-07-0", "sleep-2025-10-08-0"])
    #expect(sent[3].originalID == "sleep-2025-07-10-0")
    #expect(sent.dropFirst(3).map(\.start) == sent.dropFirst(3).map(\.start).sorted())

    let state = harness.states.current
    #expect(state.sleepBackfillCompletedThrough == lookbackStart)
    #expect(state.sleep.uploadedCount == 88)
    #expect(state.sleep.lastSuccessfulSync == now)
    #expect(Set(state.sleepLookbackSent.keys) == Set(sent.prefix(3).map(\.originalID)))
    #expect(report.uploaded[.sleep] == 88)
  }

  @Test func recordsFollowTheContract() async throws {
    let bedtime = today.addingTimeInterval(-14 * 3600)  // yesterday 22:00
    let harness = harness(sleep: EngineFixtures.night(from: bedtime))
    _ = await harness.engine.sync(reason: .healthChange(.sleep))
    let record = try #require(await harness.client.sleepBatches.first?.first)
    #expect(record.originalID == "sleep-2025-10-07-0")
    #expect(record.source == "Apple")
    #expect(record.device == "Apple Health")
    #expect(record.app == "NocturneSync 0.1.0")
    #expect(record.timeZoneIdentifier == utc.identifier)
    #expect(record.start == bedtime)
  }

  @Test func emptyWindowsSendNothingAndStillCommit() async throws {
    let harness = harness()
    let report = await harness.engine.sync(reason: .launch)
    #expect(report.results[.sleep]?.isCompleted == true)
    #expect(await harness.client.calls.isEmpty)
    #expect(harness.states.current.sleepBackfillCompletedThrough == lookbackStart)
    #expect(harness.states.current.sleep.uploadedCount == 0)
  }

  @Test func unchangedLookbackSendsNothingAndWritesNothing() async throws {
    let harness = harness(sleep: nights(from: lookbackStart, to: now))
    _ = await harness.engine.sync(reason: .launch)
    let callsAfterFirst = await harness.client.calls.count
    let writesAfterFirst = harness.states.history.count
    #expect(callsAfterFirst == 1)

    harness.clock.advance(by: 60)
    _ = await harness.engine.sync(reason: .healthChange(.sleep))

    #expect(await harness.client.calls.count == callsAfterFirst)
    #expect(harness.states.history.count == writesAfterFirst + 1)  // status timestamp only
  }

  @Test func onlyChangedSessionsAreResentAndManualResendsAll() async throws {
    let samples = nights(from: lookbackStart, to: now)
    let harness = harness(sleep: samples)
    _ = await harness.engine.sync(reason: .launch)

    // A late Watch sync extends last night by an hour: one session changes.
    var extended = samples.last!
    extended.end = extended.end.addingTimeInterval(3600)
    await harness.health.setSleepSamples([extended])
    harness.clock.advance(by: 60)
    _ = await harness.engine.sync(reason: .healthChange(.sleep))
    let second = try #require(await harness.client.sleepBatches.last)
    #expect(second.map(\.originalID) == ["sleep-2025-10-08-0"])
    #expect(second[0].end == extended.end)
    #expect(await harness.client.calls.count == 2)

    harness.clock.advance(by: 60)
    _ = await harness.engine.sync(reason: .manual)
    #expect(await harness.client.sleepBatches.last?.count == 3)
    #expect(await harness.client.calls.count == 3)
  }

  @Test func aLateNapRenumbersTheDayWithoutOrphaningNames() async throws {
    let bedtime = today.addingTimeInterval(-14 * 3600)
    let harness = harness(sleep: EngineFixtures.night(from: bedtime))
    _ = await harness.engine.sync(reason: .launch)
    #expect(await harness.client.sleepBatches.last?.map(\.originalID) == ["sleep-2025-10-07-0"])

    await harness.health.setSleepSamples(EngineFixtures.nap(at: bedtime.addingTimeInterval(-5 * 3600)))
    harness.clock.advance(by: 60)
    _ = await harness.engine.sync(reason: .healthChange(.sleep))
    let resent = try #require(await harness.client.sleepBatches.last)
    #expect(resent.map(\.originalID) == ["sleep-2025-10-07-0", "sleep-2025-10-07-1"])
    #expect(resent.map(\.kind) == [.nap, .overnight])
  }

  @Test func sessionsStartingBeforeAWindowAreLeftToTheirOwnDay() async throws {
    // A session that starts at 11:00 and runs past noon belongs to the earlier day. Its samples
    // overlap the later day's read window but are not uploaded by it.
    let sleepDay = lookbackStart.addingTimeInterval(-day)
    let crossing = EngineFixtures.nap(at: lookbackStart.addingTimeInterval(-3600), minutes: 180)
    let states = InMemorySyncStateStore(SyncState(sleepBackfillCompletedThrough: sleepDay))
    let harness = harness(sleep: crossing, states: states)
    _ = await harness.engine.sync(reason: .launch)
    let batches = await harness.client.sleepBatches
    #expect(batches.count == 1)
    #expect(batches[0].map(\.originalID) == ["sleep-2025-10-05-0"])
    #expect(harness.states.current.sleepLookbackSent.isEmpty)
  }

  @Test func watermarkMovesOnlyAfterADayWasUploaded() async throws {
    let samples = nights(from: initialWatermark, to: now)
    // Lookback succeeds, the first backfill day fails with an error that is not retried.
    let rejected = NocturneClientError.badRequest(ProblemDetails(detail: "bad sleep"))
    let harness = harness(sleep: samples, client: FakeNocturneClient(script: [nil, rejected]))
    let report = await harness.engine.sync(reason: .launch)
    guard case .upload(.badRequest) = report.results[.sleep]?.failure else {
      Issue.record("expected a bad request failure, got \(String(describing: report.results[.sleep]))")
      return
    }
    #expect(harness.states.current.sleepBackfillCompletedThrough == initialWatermark)
    #expect(harness.states.current.sleep.uploadedCount == 0)
    #expect(harness.states.current.sleep.lastError?.message == "bad sleep")

    harness.clock.advance(by: 3600)
    _ = await harness.engine.sync(reason: .launch)
    #expect(harness.states.current.sleepBackfillCompletedThrough == lookbackStart)
    #expect(harness.states.current.sleep.uploadedCount == 88)
  }

  @Test func lockedHealthDefersWithoutTouchingState() async throws {
    let harness = harness(sleep: nights(from: lookbackStart, to: now))
    await harness.health.failNextSleepQueries(.databaseInaccessible)
    let report = await harness.engine.sync(reason: .launch)
    #expect(report.results[.sleep]?.isDeferred == true)
    #expect(await harness.client.calls.isEmpty)
    #expect(harness.states.current.sleep.lastSuccessfulSync == nil)
    #expect(harness.states.current.sleep.lastError == nil)
    #expect(harness.states.current.sleepBackfillCompletedThrough == initialWatermark)
  }

  @Test func cancellationStopsAtADayBoundaryAndKeepsCommittedDays() async throws {
    // Cancelled while the third backfill day's batch is in flight: it commits, the fourth never starts.
    let client = FakeNocturneClient(onCall: { index in
      if index == 3 { withUnsafeCurrentTask { $0?.cancel() } }
    })
    let harness = harness(sleep: nights(from: initialWatermark, to: now), client: client)

    let report = await harness.engine.sync(reason: .backgroundRefresh)

    #expect(report.results[.sleep]?.isCancelled == true)
    #expect(await harness.client.calls.count == 4)
    #expect(harness.states.current.sleepBackfillCompletedThrough == initialWatermark.addingTimeInterval(3 * day))
    #expect(harness.states.current.sleep.uploadedCount == 3)
    #expect(harness.states.current.sleep.lastSuccessfulSync == nil)
  }

  @Test func sessionsCarryTheirBiometricSummary() async throws {
    let bedtime = today.addingTimeInterval(-14 * 3600)  // yesterday 22:00
    let readings = [
      BiometricSample(kind: .heartRate, date: bedtime.addingTimeInterval(600), value: 54),
      BiometricSample(kind: .heartRate, date: bedtime.addingTimeInterval(7800), value: 80),  // awake interval
      BiometricSample(kind: .heartRateVariability, date: bedtime.addingTimeInterval(900), value: 47),
      BiometricSample(kind: .respiratoryRate, date: bedtime.addingTimeInterval(1200), value: 13.5),
      BiometricSample(kind: .oxygenSaturation, date: bedtime.addingTimeInterval(1500), value: 0.96),
    ]
    let harness = harness(sleep: EngineFixtures.night(from: bedtime), biometrics: readings)
    _ = await harness.engine.sync(reason: .healthChange(.sleep))

    let record = try #require(await harness.client.sleepBatches.first?.first)
    #expect(
      record.biometrics
        == SleepBiometrics(
          averageHeartRate: 54, minimumHeartRate: 54, averageHRV: 47, averageRespiratoryRate: 13.5,
          averageOxygenSaturation: 96))
    #expect(await harness.health.biometricQueries == [DateInterval(start: record.start, end: record.end)])
  }

  @Test func aLateReadingResendsTheSession() async throws {
    let bedtime = today.addingTimeInterval(-14 * 3600)
    let harness = harness(
      sleep: EngineFixtures.night(from: bedtime),
      biometrics: [BiometricSample(kind: .heartRate, date: bedtime.addingTimeInterval(600), value: 54)])
    _ = await harness.engine.sync(reason: .healthChange(.sleep))
    harness.clock.advance(by: 60)
    _ = await harness.engine.sync(reason: .healthChange(.sleep))
    #expect(await harness.client.calls.count == 1)

    await harness.health.appendBiometrics([
      BiometricSample(kind: .heartRateVariability, date: bedtime.addingTimeInterval(900), value: 52)
    ])
    harness.clock.advance(by: 60)
    _ = await harness.engine.sync(reason: .healthChange(.sleep))
    let resent = try #require(await harness.client.sleepBatches.last?.first)
    #expect(await harness.client.calls.count == 2)
    #expect(resent.biometrics.averageHRV == 52)
    #expect(resent.biometrics.averageHeartRate == 54)
  }

  @Test func inBedOnlySessionsCostNoBiometricQuery() async throws {
    let bedtime = today.addingTimeInterval(-14 * 3600)
    let inBed = EngineFixtures.night(from: bedtime).filter { $0.stage == .inBed }
    let harness = harness(sleep: inBed)
    _ = await harness.engine.sync(reason: .healthChange(.sleep))
    #expect(await harness.client.sleepBatches.first?.first?.biometrics.isEmpty == true)
    #expect(await harness.health.biometricQueries.isEmpty)
  }

  @Test func lockedBiometricsDeferTheRun() async throws {
    let harness = harness(sleep: EngineFixtures.night(from: today.addingTimeInterval(-14 * 3600)))
    await harness.health.failNextBiometricQueries(.databaseInaccessible)
    let report = await harness.engine.sync(reason: .launch)
    #expect(report.results[.sleep]?.isDeferred == true)
    #expect(await harness.client.calls.isEmpty)
    #expect(harness.states.current.sleepLookbackSent.isEmpty)
    #expect(harness.states.current.sleep.lastError == nil)
  }

  @Test func invalidSamplesAreSkipped() async throws {
    var samples = EngineFixtures.night(from: today.addingTimeInterval(-14 * 3600))
    samples[1].end = samples[1].start
    let harness = harness(sleep: samples)
    _ = await harness.engine.sync(reason: .healthChange(.sleep))
    let record = try #require(await harness.client.sleepBatches.first?.first)
    #expect(record.stages.count == samples.count - 1)
  }

  @Test func incrementalRunCoversTheLookbackAndOnlyTheGap() async throws {
    let harness = harness(sleep: nights(from: initialWatermark, to: now))
    _ = await harness.engine.sync(reason: .launch)
    let queriesBefore = await harness.health.sleepQueries.count

    harness.clock.advance(by: 5 * day)
    _ = await harness.engine.sync(reason: .healthChange(.sleep))

    let later = Array(await harness.health.sleepQueries.dropFirst(queriesBefore))
    let laterToday = SleepDays.dayStart(containing: now.addingTimeInterval(5 * day), in: utc)
    let laterLookbackStart = laterToday.addingTimeInterval(-2 * day)
    #expect(later.first == DateInterval(start: laterLookbackStart - day, end: now.addingTimeInterval(5 * day) + day))
    #expect(later.dropFirst().map(\.start) == (0..<5).map { lookbackStart.addingTimeInterval(Double($0) * day) - day })
    #expect(harness.states.current.sleepBackfillCompletedThrough == laterLookbackStart)
  }
}
