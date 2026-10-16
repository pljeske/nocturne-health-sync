import Foundation

/// Steps: source-prioritised 5-minute bucket totals, never raw samples.
///
/// Statistics queries have no anchor, so each run:
/// 1. uploads every non-empty bucket of the lookback window `[now - 24 h, now)`. It writes no state;
///    the server's upsert makes the re-upload idempotent, and it picks up late Watch syncs;
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
    _ = try await upload(lookback, context)

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

  /// Reads, maps and uploads one window. Returns the number of records sent; zero sends no request.
  private func upload(_ window: DateInterval, _ context: SyncContext) async throws(PipelineStop) -> Int {
    guard !Task.isCancelled else { throw .cancelled }
    let totals: [StepBucketTotal]
    do {
      totals = try await context.health.stepTotals(in: window, bucketSeconds: bucketSeconds)
    } catch .databaseInaccessible {
      throw .deferred
    } catch {
      throw .failed(.health(error))
    }

    let records = map(totals, context)
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
    return records.count
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
