import Foundation

/// The single place sync happens. Observer callbacks, background refresh, launch and "Sync now" all
/// call `sync(reason:)`. Runs never overlap: a request during a run queues one follow-up run, and any
/// further requests join that follow-up (their data types are merged into it). The engine is the only
/// writer of anchors and sync state; pipelines commit through `SyncContext`.
public actor SyncEngine {
  private let health: any HealthSource
  private let client: any NocturneClient
  private let anchors: any AnchorStore
  private let stateStore: any SyncStateStore
  private let pipelines: [any SyncPipeline]
  private let app: String
  private let retrier: Retrier
  private let now: @Sendable () -> Date
  private let timeZone: @Sendable () -> TimeZone

  private struct Run {
    let id: Int
    let task: Task<SyncReport, Never>
  }

  private var active: Run?
  private var activeTypes: Set<HealthDataType> = []
  private var queued: Run?
  private var queuedTypes: Set<HealthDataType> = []
  private var lastRunID = 0
  /// Callers waiting on the queued run. Test observability only.
  private(set) var queuedRequestCount = 0

  private var loadedState: SyncState?
  private var committedThisRun: [HealthDataType: Int] = [:]

  public init(
    health: any HealthSource,
    client: any NocturneClient,
    anchors: any AnchorStore,
    stateStore: any SyncStateStore,
    pipelines: [any SyncPipeline],
    app: String,
    retryPolicy: RetryPolicy = .default,
    now: @escaping @Sendable () -> Date = Date.init,
    timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.current },
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
    unitRandom: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
  ) {
    precondition(Set(pipelines.map(\.type)).count == pipelines.count, "one pipeline per data type")
    self.health = health
    self.client = client
    self.anchors = anchors
    self.stateStore = stateStore
    self.pipelines = pipelines
    self.app = app
    self.retrier = Retrier(policy: retryPolicy, sleep: sleep, unitRandom: unitRandom)
    self.now = now
    self.timeZone = timeZone
  }

  /// The last loaded or written state, for the status screen. Nil until the first run loads it.
  public var state: SyncState? { loadedState }

  /// The persisted state, loading it if no run has yet, for the status screen at launch. Nil when the
  /// file cannot be read (e.g. before first unlock); a corrupt file reads as the default state.
  public func persistedState() -> SyncState? {
    try? loadStateIfNeeded()
  }

  /// Runs (or joins a queued run of) the pipelines `reason` selects and returns that run's report.
  public func sync(reason: SyncReason) async -> SyncReport {
    if let queued {
      queuedTypes.formUnion(reason.types)
      queuedRequestCount += 1
      return await queued.task.value
    }
    lastRunID += 1
    let id = lastRunID
    let previous = active?.task
    let task = Task {
      if let previous { _ = await previous.value }
      return await self.execute(runID: id)
    }
    let run = Run(id: id, task: task)
    if active == nil {
      active = run
      activeTypes = reason.types
    } else {
      queued = run
      queuedTypes = reason.types
      queuedRequestCount = 1
    }
    return await task.value
  }

  /// Cancels the running and the queued run, e.g. from a background task's expiration handler.
  /// Pipelines stop at the next batch boundary; committed batches stay committed.
  public func cancelCurrentRun() {
    active?.task.cancel()
    queued?.task.cancel()
  }

  private func execute(runID: Int) async -> SyncReport {
    if let queued, queued.id == runID {
      active = queued
      activeTypes = queuedTypes
      self.queued = nil
      queuedTypes = []
      queuedRequestCount = 0
    }
    defer {
      if active?.id == runID {
        active = nil
        activeTypes = []
      }
    }
    return await performRun(types: activeTypes)
  }

  private func performRun(types: Set<HealthDataType>) async -> SyncReport {
    let startedAt = now()
    var report = SyncReport(startedAt: startedAt, finishedAt: startedAt)
    let selected = pipelines.filter { types.contains($0.type) }

    do {
      _ = try loadStateIfNeeded()
    } catch {
      for pipeline in selected { report.results[pipeline.type] = .failed(error) }
      report.finishedAt = now()
      return report
    }

    committedThisRun = [:]
    let zone = timeZone()
    for pipeline in selected {
      let type = pipeline.type
      guard !Task.isCancelled else {
        report.results[type] = .cancelled
        break
      }
      let context = SyncContext(
        type: type, health: health, client: client, now: startedAt, timeZone: zone, app: app, retrier: retrier,
        engine: self)
      let result = record(await pipeline.run(context), for: type)
      report.results[type] = result
      report.uploaded[type] = committedThisRun[type, default: 0]
      if result.stopsRun { break }
    }
    report.finishedAt = now()
    return report
  }

  /// Persists the end-of-run status of one type. Deferred and cancelled runs write nothing.
  private func record(_ result: PipelineResult, for type: HealthDataType) -> PipelineResult {
    guard var next = loadedState else { return result }
    switch result {
    case .completed:
      next[type].lastSuccessfulSync = now()
      next[type].lastError = nil
      EngineLog.finished(type, uploaded: committedThisRun[type, default: 0])
    case .failed(let failure):
      next[type].lastError = SyncState.Failure(message: failure.message, occurredAt: now())
      EngineLog.failed(type, failure)
    case .deferred, .cancelled:
      return result
    }
    do {
      try persist(next)
    } catch {
      EngineLog.statusNotSaved(type, error)
      if case .completed = result { return .failed(error) }
    }
    return result
  }

  // MARK: Store access (only through here)

  private func loadStateIfNeeded() throws(SyncFailure) -> SyncState {
    if let loadedState { return loadedState }
    let loaded: SyncState
    do {
      loaded = try stateStore.load()
    } catch let error as FileStoreError {
      // Only an unreadable file is reset. A read failure (e.g. before first unlock) must not replace
      // good state with defaults.
      guard case .corrupt = error else { throw .storage(error) }
      EngineLog.resetCorruptState(error)
      loaded = SyncState()
    } catch {
      throw .storage(error)
    }
    loadedState = loaded
    return loaded
  }

  private func persist(_ next: SyncState) throws(SyncFailure) {
    do {
      try stateStore.save(next)
    } catch {
      throw .storage(error)
    }
    loadedState = next
  }

  func currentRunState() -> SyncState {
    guard let loadedState else { preconditionFailure("pipelines run only after the state is loaded") }
    return loadedState
  }

  func loadAnchor(for type: HealthDataType) throws(SyncFailure) -> Data? {
    do {
      return try anchors.loadAnchor(for: type)
    } catch {
      throw .storage(error)
    }
  }

  func clearAnchor(for type: HealthDataType) throws(SyncFailure) {
    do {
      try anchors.clearAnchor(for: type)
    } catch {
      throw .storage(error)
    }
  }

  func commit(
    _ type: HealthDataType, anchor: Data?, uploaded: Int, update: @Sendable (inout SyncState) -> Void
  ) throws(SyncFailure) {
    if let anchor {
      do {
        try anchors.saveAnchor(anchor, for: type)
      } catch {
        throw .storage(error)
      }
    }
    var next = currentRunState()
    next[type].uploadedCount += uploaded
    update(&next)
    try persist(next)
    committedThisRun[type, default: 0] += uploaded
  }
}
