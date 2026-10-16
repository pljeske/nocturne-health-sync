import Foundation

/// What started a sync run. Decides which data types run.
public enum SyncReason: Sendable, Hashable {
  case launch
  case manual
  case backgroundRefresh
  /// An `HKObserverQuery` fired for this type; only its pipeline runs.
  case healthChange(HealthDataType)

  var types: Set<HealthDataType> {
    switch self {
    case .healthChange(let type): [type]
    case .launch, .manual, .backgroundRefresh: Set(HealthDataType.allCases)
    }
  }
}

/// How one data type's part of a run ended.
public enum PipelineResult: Sendable {
  /// Everything Health had was uploaded and committed.
  case completed
  /// Health is locked. Nothing was committed or recorded; a later trigger resumes.
  case deferred
  /// The run was cancelled at a batch boundary. Committed batches stay committed.
  case cancelled
  case failed(SyncFailure)

  var stopsRun: Bool {
    switch self {
    case .completed: false
    case .deferred, .cancelled: true
    case .failed(let failure): failure.stopsRun
    }
  }
}

/// One data type's read → map → batch → upload → commit loop. Adding a type means adding a pipeline;
/// the engine does not change. A pipeline never touches stores directly: it reads and commits
/// through `SyncContext`, which forwards to the engine, the only writer.
public protocol SyncPipeline: Sendable {
  var type: HealthDataType { get }
  func run(_ context: SyncContext) async -> PipelineResult
}

/// What a pipeline gets for one run.
public struct SyncContext: Sendable {
  public let type: HealthDataType
  public let health: any HealthSource
  public let client: any NocturneClient
  /// Start of the run. Windows and cutoffs are computed from it, so one run is internally consistent.
  public let now: Date
  /// Device time zone for `utcOffset` when a sample carries none.
  public let timeZone: TimeZone
  /// `app` field of every record: `NocturneConstants.appIdentifier(version:)`.
  public let app: String
  let retrier: Retrier
  let engine: SyncEngine

  /// Runs one upload with the run's retry policy.
  public func withRetries(_ operation: () async throws(NocturneClientError) -> Void) async throws(NocturneClientError) {
    try await retrier.run(operation)
  }

  public func state() async -> SyncState {
    await engine.currentRunState()
  }

  public func loadAnchor() async throws(SyncFailure) -> Data? {
    try await engine.loadAnchor(for: type)
  }

  public func clearAnchor() async throws(SyncFailure) {
    try await engine.clearAnchor(for: type)
  }

  /// Commits one batch: saves `anchor` (when given), then adds `uploaded` to the type's count and
  /// applies `update`, in one state write. Call only after every record of the batch got a 2xx.
  public func commit(
    anchor: Data?, uploaded: Int, update: @escaping @Sendable (inout SyncState) -> Void = { _ in }
  ) async throws(SyncFailure) {
    try await engine.commit(type, anchor: anchor, uploaded: uploaded, update: update)
  }

  /// Writes state that is not tied to a batch (e.g. the heart rate cutoff, before the first query).
  public func update(_ body: @escaping @Sendable (inout SyncState) -> Void) async throws(SyncFailure) {
    try await engine.commit(type, anchor: nil, uploaded: 0, update: body)
  }
}

/// Outcome of one engine run, per data type that ran.
public struct SyncReport: Sendable {
  public var startedAt: Date
  public var finishedAt: Date
  public var results: [HealthDataType: PipelineResult] = [:]
  /// Records committed during this run.
  public var uploaded: [HealthDataType: Int] = [:]

  public init(startedAt: Date, finishedAt: Date) {
    self.startedAt = startedAt
    self.finishedAt = finishedAt
  }
}
