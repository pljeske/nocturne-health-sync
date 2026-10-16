import Foundation

/// Heart rate: anchored pages of raw samples, one record per sample.
///
/// Per page: read (≤ `pageLimit` samples at or after the fixed cutoff) → map → upload in batches of
/// `NocturneAPI.uploadChunkSize` → commit the page's anchor. The anchor moves only after every batch
/// of the page got a 2xx; a failure or cancellation part-way re-sends the whole page next run, which
/// the server's upsert absorbs.
public struct HeartRatePipeline: SyncPipeline {
  public static let defaultPageLimit = 2000
  public static let backfillDays = 90

  public let type = HealthDataType.heartRate
  public let pageLimit: Int
  public let backfillDays: Int

  public init(pageLimit: Int = HeartRatePipeline.defaultPageLimit, backfillDays: Int = HeartRatePipeline.backfillDays) {
    precondition(pageLimit > 0, "an unbounded page can exceed one background execution")
    self.pageLimit = pageLimit
    self.backfillDays = backfillDays
  }

  public func run(_ context: SyncContext) async -> PipelineResult {
    do {
      try await sync(context)
      return .completed
    } catch {
      return error.result
    }
  }

  private enum Stop: Error {
    case deferred
    case cancelled
    case failed(SyncFailure)

    var result: PipelineResult {
      switch self {
      case .deferred: .deferred
      case .cancelled: .cancelled
      case .failed(let failure): .failed(failure)
      }
    }
  }

  private func sync(_ context: SyncContext) async throws(Stop) {
    let cutoff = try await cutoff(context)
    var anchor: Data?
    do {
      anchor = try await context.loadAnchor()
    } catch {
      throw .failed(error)
    }
    var anchorReset = false

    while true {
      guard !Task.isCancelled else { throw .cancelled }
      let page: HeartRatePage
      do {
        page = try await context.health.heartRateSamples(after: anchor, startingAt: cutoff, limit: pageLimit)
      } catch .databaseInaccessible {
        throw .deferred
      } catch .invalidAnchor where anchor != nil && !anchorReset {
        // Start over from the cutoff; re-uploads are upserts.
        do {
          try await context.clearAnchor()
        } catch {
          throw .failed(error)
        }
        anchor = nil
        anchorReset = true
        continue
      } catch {
        throw .failed(.health(error))
      }

      let records = map(page.samples, timeZone: context.timeZone)
      for chunk in records.chunks(ofCount: NocturneAPI.uploadChunkSize) {
        guard !Task.isCancelled else { throw .cancelled }
        let batch = Array(chunk)
        do {
          try await context.withRetries { () throws(NocturneClientError) in
            try await context.client.uploadHeartRates(batch)
          }
        } catch .cancelled {
          throw .cancelled
        } catch {
          throw .failed(.upload(error))
        }
      }

      let drained = !page.mightHaveMore
      do {
        try await context.commit(anchor: page.anchor, uploaded: records.count) { state in
          if drained { state.heartRateBackfillComplete = true }
        }
      } catch {
        throw .failed(error)
      }
      anchor = page.anchor
      if drained { return }
    }
  }

  /// The persisted cutoff, or `now - backfillDays` persisted before the first query (decision 7).
  private func cutoff(_ context: SyncContext) async throws(Stop) -> Date {
    if let existing = await context.state().heartRateBackfillStart { return existing }
    let cutoff = context.now.addingTimeInterval(-TimeInterval(backfillDays) * 86_400)
    do {
      try await context.update { $0.heartRateBackfillStart = cutoff }
    } catch {
      throw .failed(error)
    }
    return cutoff
  }

  /// Maps every sample, skipping (and logging) one that cannot be represented. HealthKit validates
  /// heart rate values, so this is defensive: one bad sample must not pin the anchor forever.
  private func map(_ samples: [HeartRateSample], timeZone: TimeZone) -> [HeartRateRecord] {
    samples.compactMap { sample -> HeartRateRecord? in
      do throws(MappingError) {
        return try HeartRateMapper.record(from: sample, deviceTimeZone: timeZone)
      } catch {
        EngineLog.skippedSample(.heartRate, error)
        return nil
      }
    }
  }
}
