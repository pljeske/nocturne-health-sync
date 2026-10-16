import Foundation
import Synchronization
import Testing

@testable import NocturneSyncCore

enum EngineFixtures {
  /// 2025-10-09 08:53:20 UTC.
  static let start = Date(timeIntervalSince1970: 1_760_000_000)
  static let utc = TimeZone(identifier: "UTC")!
  static let app = "NocturneSync 0.1.0"

  /// `count` samples five seconds apart, beginning one day before `start`.
  static func heartRates(_ count: Int, from first: Int = 0, at base: Date = start.addingTimeInterval(-86_400))
    -> [HeartRateSample]
  {
    (first..<(first + count)).map { index in
      HeartRateSample(
        id: UUID(uuidString: String(format: "%08X-0000-4000-8000-000000000000", index))!,
        date: base.addingTimeInterval(TimeInterval(index) * 5),
        beatsPerMinute: 60 + Double(index % 60),
        device: "Watch7,1")
    }
  }
}

/// A settable clock.
final class TestClock: Sendable {
  private let current: Mutex<Date>

  init(_ start: Date = EngineFixtures.start) {
    current = Mutex(start)
  }

  var now: Date { current.withLock { $0 } }

  func advance(by seconds: TimeInterval) {
    current.withLock { $0 = $0.addingTimeInterval(seconds) }
  }
}

/// Records requested sleeps instead of sleeping.
final class SleepRecorder: Sendable {
  private let recorded = Mutex<[TimeInterval]>([])

  var delays: [TimeInterval] { recorded.withLock { $0 } }

  func sleep(_ seconds: TimeInterval) {
    recorded.withLock { $0.append(seconds) }
  }
}

/// Opens once; every waiter before that suspends.
actor Gate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  var waiting: Int { waiters.count }

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }
}

/// Everything an engine test needs, wired with fakes.
struct EngineHarness {
  let health: FakeHealthSource
  let client: FakeNocturneClient
  let anchors: InMemoryAnchorStore
  let states: InMemorySyncStateStore
  let clock: TestClock
  let sleeps: SleepRecorder
  let engine: SyncEngine

  init(
    health: FakeHealthSource = FakeHealthSource(),
    client: FakeNocturneClient = FakeNocturneClient(),
    anchors: InMemoryAnchorStore = InMemoryAnchorStore(),
    states: InMemorySyncStateStore = InMemorySyncStateStore(),
    pipelines: [any SyncPipeline] = [HeartRatePipeline()],
    retryPolicy: RetryPolicy = .default,
    unitRandom: Double = 0.5
  ) {
    let clock = TestClock()
    let sleeps = SleepRecorder()
    self.health = health
    self.client = client
    self.anchors = anchors
    self.states = states
    self.clock = clock
    self.sleeps = sleeps
    engine = SyncEngine(
      health: health, client: client, anchors: anchors, stateStore: states, pipelines: pipelines,
      app: EngineFixtures.app, retryPolicy: retryPolicy, now: { clock.now }, timeZone: { EngineFixtures.utc },
      sleep: { sleeps.sleep($0) }, unitRandom: { unitRandom })
  }
}

extension PipelineResult {
  var isCompleted: Bool { if case .completed = self { true } else { false } }
  var isDeferred: Bool { if case .deferred = self { true } else { false } }
  var isCancelled: Bool { if case .cancelled = self { true } else { false } }
  var failure: SyncFailure? { if case .failed(let failure) = self { failure } else { nil } }
}

/// Polls `condition` until it holds, failing the test after about a second.
func eventually(
  _ condition: @Sendable () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation
) async throws {
  for _ in 0..<1000 {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(1))
  }
  Issue.record("condition never became true", sourceLocation: sourceLocation)
}
