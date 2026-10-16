import Foundation
import Synchronization
import Testing

@testable import NocturneSyncCore

/// A pipeline whose behaviour is a closure, to test the engine without HealthKit semantics.
struct StubPipeline: SyncPipeline {
  let type: HealthDataType
  let body: @Sendable (SyncContext) async -> PipelineResult

  func run(_ context: SyncContext) async -> PipelineResult {
    await body(context)
  }
}

/// Counts invocations per type.
final class Invocations: Sendable {
  private let counts = Mutex<[HealthDataType]>([])
  var all: [HealthDataType] { counts.withLock { $0 } }
  func record(_ type: HealthDataType) { counts.withLock { $0.append(type) } }
}

@Suite struct SyncEngineTests {
  func stub(_ type: HealthDataType, _ invocations: Invocations, result: PipelineResult) -> StubPipeline {
    StubPipeline(type: type) { _ in
      invocations.record(type)
      return result
    }
  }

  @Test func runsPipelinesInOrderAndRecordsEachStatus() async throws {
    let invocations = Invocations()
    let harness = EngineHarness(pipelines: [
      stub(.heartRate, invocations, result: .completed),
      stub(.stepCount, invocations, result: .failed(.upload(.badRequest(ProblemDetails(detail: "bad step"))))),
    ])

    let report = await harness.engine.sync(reason: .manual)

    #expect(invocations.all == [.heartRate, .stepCount])
    #expect(report.results[.heartRate]?.isCompleted == true)
    #expect(report.results[.stepCount]?.failure != nil)
    let state = harness.states.current
    #expect(state.heartRate.lastSuccessfulSync == EngineFixtures.start)
    #expect(state.stepCount.lastError == SyncState.Failure(message: "bad step", occurredAt: EngineFixtures.start))
    #expect(state.stepCount.lastSuccessfulSync == nil)
    #expect(await harness.engine.state == state)
  }

  @Test func successClearsAnEarlierError() async throws {
    let earlier = SyncState(heartRate: .init(lastError: .init(message: "old", occurredAt: .distantPast)))
    let invocations = Invocations()
    let harness = EngineHarness(
      states: InMemorySyncStateStore(earlier), pipelines: [stub(.heartRate, invocations, result: .completed)])
    _ = await harness.engine.sync(reason: .manual)
    #expect(harness.states.current.heartRate.lastError == nil)
  }

  @Test(arguments: [
    PipelineResult.failed(.upload(.auth(.signedOut))), .failed(.upload(.setupRequired(message: nil))),
    .failed(.upload(.transport(URLError(.notConnectedToInternet)))), .deferred, .cancelled,
  ])
  func runWideStopsSkipTheRemainingTypes(first: PipelineResult) async throws {
    let invocations = Invocations()
    let harness = EngineHarness(pipelines: [
      stub(.heartRate, invocations, result: first), stub(.stepCount, invocations, result: .completed),
    ])
    let report = await harness.engine.sync(reason: .manual)
    #expect(invocations.all == [.heartRate])
    #expect(report.results[.stepCount] == nil)
  }

  @Test func typeSpecificFailureDoesNotStopTheRun() async throws {
    let invocations = Invocations()
    let harness = EngineHarness(pipelines: [
      stub(.heartRate, invocations, result: .failed(.upload(.forbidden(nil)))),
      stub(.stepCount, invocations, result: .completed),
    ])
    _ = await harness.engine.sync(reason: .manual)
    #expect(invocations.all == [.heartRate, .stepCount])
  }

  @Test func deferredAndCancelledWriteNothing() async throws {
    for result in [PipelineResult.deferred, .cancelled] {
      let harness = EngineHarness(pipelines: [stub(.heartRate, Invocations(), result: result)])
      _ = await harness.engine.sync(reason: .manual)
      #expect(harness.states.history.isEmpty)
    }
  }

  @Test func healthChangeRunsOnlyThatType() async throws {
    let invocations = Invocations()
    let harness = EngineHarness(pipelines: [
      stub(.heartRate, invocations, result: .completed), stub(.stepCount, invocations, result: .completed),
    ])
    let report = await harness.engine.sync(reason: .healthChange(.stepCount))
    #expect(invocations.all == [.stepCount])
    #expect(report.results.keys.sorted { $0.rawValue < $1.rawValue } == [.stepCount])
  }

  @Test func requestsDuringARunCoalesceIntoOneFollowUp() async throws {
    let gate = Gate()
    let invocations = Invocations()
    let blocking = StubPipeline(type: .heartRate) { _ in
      invocations.record(.heartRate)
      if invocations.all.count == 1 { await gate.wait() }
      return .completed
    }
    let steps = stub(.stepCount, invocations, result: .completed)
    let harness = EngineHarness(pipelines: [blocking, steps])
    let engine = harness.engine

    async let first = engine.sync(reason: .healthChange(.heartRate))
    try await eventually { await gate.waiting == 1 }
    async let second = engine.sync(reason: .healthChange(.heartRate))
    try await eventually { await engine.queuedRequestCount == 1 }
    async let third = engine.sync(reason: .healthChange(.stepCount))
    try await eventually { await engine.queuedRequestCount == 2 }
    await gate.open()

    let reports = await [first, second, third]
    // One initial run (heart rate) and one follow-up covering both queued requests.
    #expect(invocations.all == [.heartRate, .heartRate, .stepCount])
    #expect(reports[0].results.count == 1)
    #expect(reports[1].results.count == 2)
    #expect(reports[1].startedAt == reports[2].startedAt)

    _ = await engine.sync(reason: .healthChange(.stepCount))
    #expect(invocations.all == [.heartRate, .heartRate, .stepCount, .stepCount])
  }

  @Test func cancelCurrentRunStopsAtTheNextBoundary() async throws {
    let gate = Gate()
    let invocations = Invocations()
    let blocking = StubPipeline(type: .heartRate) { _ in
      invocations.record(.heartRate)
      await gate.wait()
      return Task.isCancelled ? .cancelled : .completed
    }
    let harness = EngineHarness(pipelines: [blocking, stub(.stepCount, invocations, result: .completed)])
    let engine = harness.engine

    async let report = engine.sync(reason: .manual)
    try await eventually { await gate.waiting == 1 }
    await engine.cancelCurrentRun()
    await gate.open()

    #expect(await report.results[.heartRate]?.isCancelled == true)
    #expect(invocations.all == [.heartRate])
    #expect(harness.states.history.isEmpty)
  }

  @Test func corruptStateIsResetAndTheRunProceeds() async throws {
    let states = InMemorySyncStateStore()
    states.loadError = FileStoreError.corrupt(URL(filePath: "/state.json"), underlying: CocoaError(.coderReadCorrupt))
    let harness = EngineHarness(states: states, pipelines: [stub(.heartRate, Invocations(), result: .completed)])
    let report = await harness.engine.sync(reason: .manual)
    #expect(report.results[.heartRate]?.isCompleted == true)
    #expect(states.history.last?.heartRate.lastSuccessfulSync == EngineFixtures.start)
  }

  @Test func unreadableStateFailsTheRunWithoutOverwritingIt() async throws {
    let states = InMemorySyncStateStore()
    states.loadError = FileStoreError.read(URL(filePath: "/state.json"), underlying: CocoaError(.fileReadNoPermission))
    let invocations = Invocations()
    let harness = EngineHarness(
      states: states,
      pipelines: [
        stub(.heartRate, invocations, result: .completed), stub(.stepCount, invocations, result: .completed),
      ])
    let report = await harness.engine.sync(reason: .manual)
    guard case .storage = report.results[.heartRate]?.failure, case .storage = report.results[.stepCount]?.failure
    else {
      Issue.record("expected storage failures, got \(report.results)")
      return
    }
    #expect(invocations.all.isEmpty)
    #expect(states.history.isEmpty)
    #expect(await harness.engine.state == nil)
  }

  @Test func persistedStateIsReadableBeforeAnyRun() async throws {
    let saved = SyncState(stepCount: .init(uploadedCount: 12))
    let harness = EngineHarness(
      states: InMemorySyncStateStore(saved), pipelines: [stub(.heartRate, Invocations(), result: .completed)])
    #expect(await harness.engine.state == nil)
    #expect(await harness.engine.persistedState() == saved)
    #expect(await harness.engine.state == saved)
  }

  @Test func persistedStateIsNilWhenUnreadable() async throws {
    let states = InMemorySyncStateStore()
    states.loadError = FileStoreError.read(URL(filePath: "/state.json"), underlying: CocoaError(.fileReadNoPermission))
    let harness = EngineHarness(states: states, pipelines: [])
    #expect(await harness.engine.persistedState() == nil)
  }

  @Test func statusWriteFailureTurnsSuccessIntoAStorageFailure() async throws {
    let states = InMemorySyncStateStore()
    states.failSaves = true
    let harness = EngineHarness(states: states, pipelines: [stub(.heartRate, Invocations(), result: .completed)])
    let report = await harness.engine.sync(reason: .manual)
    guard case .storage = report.results[.heartRate]?.failure else {
      Issue.record("expected a storage failure, got \(String(describing: report.results[.heartRate]))")
      return
    }
  }
}
