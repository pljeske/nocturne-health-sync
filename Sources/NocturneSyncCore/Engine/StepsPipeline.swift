import Foundation

/// Steps: source-prioritised 5-minute bucket totals, never raw samples.
///
/// Statistics queries have no anchor, so each run:
/// 1. reads every bucket of the lookback window `[now - 24 h, now)` and uploads those whose total
///    differs from what was last sent (`SyncState.stepLookbackSent`); an unchanged window costs no
///    request and no disk write. The server's upsert makes any re-send idempotent, and the window
///    picks up late Watch syncs. A user-requested run re-sends the whole window, so a loss on the
///    server within the last day can always be repaired by hand;
/// 2. uploads the backfill `[watermark, lookback start)` in one-day slices, oldest first, and moves the
///    watermark to each slice's end once every batch of that slice got a 2xx. The first run sets the
///    watermark to `now - 90 d`. After the initial backfill each run's slice is just the gap since the
///    previous run's lookback start.
///
/// Buckets that round to zero steps are not uploaded. A bucket that once had steps and later drops
/// to zero is therefore never zeroed on the server (known gap, see CLAUDE.md).
public struct StepsPipeline: SyncPipeline {
  public static let lookbackHours = 24
  public static let backfillDays = 90
  public static let sliceSeconds = 86_400

  public let type = HealthDataType.stepCount
  /// `device` field of every step record. A bucket is Health's merged total, so it has no single
  /// recording device; the app chooses this value.
  public let device: String
  public let lookbackHours: Int
  public let backfillDays: Int
  public let sliceSeconds: Int
  let bucketSeconds = NocturneConstants.stepBucketSeconds

  public init(
    device: String,
    lookbackHours: Int = StepsPipeline.lookbackHours,
    backfillDays: Int = StepsPipeline.backfillDays,
    sliceSeconds: Int = StepsPipeline.sliceSeconds
  ) {
    precondition(lookbackHours > 0 && backfillDays > 0, "windows must be positive")
    precondition(
      sliceSeconds > 0 && sliceSeconds.isMultiple(of: NocturneConstants.stepBucketSeconds),
      "a slice must be a whole number of buckets so watermarks stay aligned")
    self.device = device
    self.lookbackHours = lookbackHours
    self.backfillDays = backfillDays
    self.sliceSeconds = sliceSeconds
  }

  public func run(_ context: SyncContext) async -> PipelineResult {
    do {
      try await sync(context)
      return .completed
    } catch {
      return error.result
    }
  }

  private func sync(_ context: SyncContext) async throws(PipelineStop) {
    var watermark = try await watermark(context)
    let lookback = StepWindows.lookback(now: context.now, hours: lookbackHours, bucketSeconds: bucketSeconds)
    try await uploadLookback(lookback, context)

    let backfillStart = watermark
    let backfillSpan = lookback.start.timeIntervalSince(backfillStart)
    var progress = SyncProgress(type: .stepCount)
    while let slice = StepWindows.nextSlice(watermark: watermark, limit: lookback.start, sliceSeconds: sliceSeconds) {
      let uploaded = try await upload(slice, context)
      let end = slice.end
      do {
        try await context.commit(anchor: nil, uploaded: uploaded) { $0.stepBackfillCompletedThrough = end }
      } catch {
        throw .failed(error)
      }
      watermark = end
      progress.uploaded += uploaded
      progress.fractionCompleted = min(1, end.timeIntervalSince(backfillStart) / backfillSpan)
      progress.reached = end
      await context.reportProgress(progress)
    }
  }

  /// The persisted watermark (re-aligned defensively), or `now - backfillDays` persisted first.
  private func watermark(_ context: SyncContext) async throws(PipelineStop) -> Date {
    if let existing = await context.state().stepBackfillCompletedThrough {
      return StepBucket(containing: existing, bucketSeconds: bucketSeconds).start
    }
    let initial = StepWindows.initialWatermark(
      now: context.now, backfillDays: backfillDays, bucketSeconds: bucketSeconds)
    do {
      try await context.update { $0.stepBackfillCompletedThrough = initial }
    } catch {
      throw .failed(error)
    }
    return initial
  }

  /// The lookback window: only buckets whose total changed since the last send, unless the user asked
  /// for this run. Remembers what was sent only after every batch succeeded.
  private func uploadLookback(_ window: DateInterval, _ context: SyncContext) async throws(PipelineStop) {
    let current = map(try await read(window, context), context)
    let sent = await context.state().stepLookbackSent
    let changed = context.userRequested ? current : current.filter { sent[$0.syncIdentifier] != $0.metric }
    try await send(changed, context)

    let latest = Dictionary(uniqueKeysWithValues: current.map { ($0.syncIdentifier, $0.metric) })
    guard latest != sent else { return }
    do {
      try await context.update { $0.stepLookbackSent = latest }
    } catch {
      throw .failed(error)
    }
  }

  /// Reads, maps and uploads one backfill slice. Returns the number of records sent.
  private func upload(_ window: DateInterval, _ context: SyncContext) async throws(PipelineStop) -> Int {
    let records = map(try await read(window, context), context)
    try await send(records, context)
    return records.count
  }

  private func read(_ window: DateInterval, _ context: SyncContext) async throws(PipelineStop) -> [StepBucketTotal] {
    guard !Task.isCancelled else { throw .cancelled }
    do {
      return try await context.health.stepTotals(in: window, bucketSeconds: bucketSeconds)
    } catch .databaseInaccessible {
      throw .deferred
    } catch {
      throw .failed(.health(error))
    }
  }

  /// Uploads in batches; an empty array sends nothing.
  private func send(_ records: [StepCountRecord], _ context: SyncContext) async throws(PipelineStop) {
    for chunk in records.chunks(ofCount: NocturneAPI.uploadChunkSize) {
      guard !Task.isCancelled else { throw .cancelled }
      let batch = Array(chunk)
      do {
        try await context.withRetries { () throws(NocturneClientError) in
          try await context.client.uploadStepCounts(batch)
        }
      } catch .cancelled {
        throw .cancelled
      } catch {
        throw .failed(.upload(error))
      }
    }
  }

  /// Maps totals to records, dropping zero buckets and skipping (and logging) unmappable ones.
  private func map(_ totals: [StepBucketTotal], _ context: SyncContext) -> [StepCountRecord] {
    totals.compactMap { total -> StepCountRecord? in
      do throws(MappingError) {
        let record = try StepCountMapper.record(
          from: total, deviceTimeZone: context.timeZone, device: device, app: context.app)
        return record.metric > 0 ? record : nil
      } catch {
        EngineLog.skippedSample(.stepCount, error)
        return nil
      }
    }
  }
}
