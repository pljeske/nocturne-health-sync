import Foundation

/// Sleep: whole sessions rebuilt from Health's sleep samples, one Nocturne session per night or nap.
///
/// Sleep samples arrive late (the Watch writes a night after waking, and syncs later still) and get
/// edited in Health, and a session is only right once all of its samples are, so there is no anchor.
/// Each run instead:
/// 1. rebuilds every session of the lookback window, the current sleep day and the `lookbackDays`
///    before it, and re-sends those whose content differs from what was last sent
///    (`SyncState.sleepLookbackSent`); an unchanged window costs no request and no disk write. A
///    user-requested run re-sends the whole window;
/// 2. uploads the backfill `[watermark, lookback start)` one sleep day at a time, oldest first, and
///    moves the watermark to the next day start once every batch of that day got a 2xx. The first run
///    sets the watermark to the day start 90 days back.
///
/// Sleep days run from local noon to noon (`SleepDays`), and a day's sessions are always uploaded
/// together, because their names are positions within the day. Samples are read `margin` beyond a
/// window on both sides, so a session that straddles a boundary is grouped whole and attributed to
/// the day its start falls in; only sessions starting inside the window are uploaded by it.
///
/// Each session then gets its vital-sign summary (`SleepBiometrics`) from the readings Health has over
/// the session's own span. The summary is part of the content digest, so an HRV or SpO2 reading that
/// arrives after the night was first sent re-sends the session while it is in the lookback.
public struct SleepPipeline: SyncPipeline {
  public static let lookbackDays = 2
  public static let backfillDays = 90
  /// Longer than any plausible session, so no session is cut by a window edge.
  static let margin: TimeInterval = 86_400

  public let type = HealthDataType.sleep
  /// `sourceDevice` of every session. A session merges iPhone and Watch samples, so it has no single
  /// recording device; the app chooses this value.
  public let device: String
  public let lookbackDays: Int
  public let backfillDays: Int

  public init(
    device: String, lookbackDays: Int = SleepPipeline.lookbackDays, backfillDays: Int = SleepPipeline.backfillDays
  ) {
    precondition(lookbackDays >= 0 && backfillDays > 0, "windows must be positive")
    self.device = device
    self.lookbackDays = lookbackDays
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

  private func sync(_ context: SyncContext) async throws(PipelineStop) {
    let zone = context.timeZone
    var watermark = try await watermark(context)
    let today = SleepDays.dayStart(containing: context.now, in: zone)
    let lookbackStart = SleepDays.dayStart(today, offsetBy: -lookbackDays, in: zone)
    try await uploadLookback(DateInterval(start: lookbackStart, end: context.now), context)

    let backfillStart = watermark
    let backfillSpan = lookbackStart.timeIntervalSince(backfillStart)
    var progress = SyncProgress(type: .sleep)
    while watermark < lookbackStart {
      let end = min(SleepDays.dayStart(watermark, offsetBy: 1, in: zone), lookbackStart)
      let records = try await sessions(startingIn: DateInterval(start: watermark, end: end), context)
      try await send(records, context)
      do {
        try await context.commit(anchor: nil, uploaded: records.count) { $0.sleepBackfillCompletedThrough = end }
      } catch {
        throw .failed(error)
      }
      watermark = end
      progress.uploaded += records.count
      progress.fractionCompleted = min(1, end.timeIntervalSince(backfillStart) / backfillSpan)
      progress.reached = end
      await context.reportProgress(progress)
    }
  }

  /// The persisted watermark re-aligned to a day start (the zone may have changed), or the day start
  /// `backfillDays` back, persisted first.
  private func watermark(_ context: SyncContext) async throws(PipelineStop) -> Date {
    let zone = context.timeZone
    if let existing = await context.state().sleepBackfillCompletedThrough {
      return SleepDays.dayStart(containing: existing, in: zone)
    }
    let initial = SleepDays.dayStart(
      containing: context.now.addingTimeInterval(-TimeInterval(backfillDays) * 86_400), in: zone)
    do {
      try await context.update { $0.sleepBackfillCompletedThrough = initial }
    } catch {
      throw .failed(error)
    }
    return initial
  }

  /// The lookback window: only sessions whose content changed since the last send, unless the user
  /// asked for this run. Remembers what was sent only after every batch succeeded.
  private func uploadLookback(_ window: DateInterval, _ context: SyncContext) async throws(PipelineStop) {
    let current = try await sessions(startingIn: window, context)
    let sent = await context.state().sleepLookbackSent
    let changed = context.userRequested ? current : current.filter { sent[$0.originalID] != $0.contentDigest }
    try await send(changed, context)

    let latest = Dictionary(uniqueKeysWithValues: current.map { ($0.originalID, $0.contentDigest) })
    guard latest != sent else { return }
    do {
      try await context.update { $0.sleepLookbackSent = latest }
    } catch {
      throw .failed(error)
    }
  }

  /// Reads the window plus margins, builds sessions, and keeps those that start inside the window.
  private func sessions(startingIn window: DateInterval, _ context: SyncContext) async throws(PipelineStop)
    -> [SleepSessionRecord]
  {
    guard !Task.isCancelled else { throw .cancelled }
    let samples: [SleepSample]
    do {
      samples = try await context.health.sleepSamples(
        overlapping: DateInterval(start: window.start - Self.margin, end: window.end + Self.margin))
    } catch .databaseInaccessible {
      throw .deferred
    } catch {
      throw .failed(.health(error))
    }
    let valid = samples.filter { sample in
      guard sample.end > sample.start else {
        EngineLog.skippedSample(.sleep, .invalidSleepInterval(start: sample.start, end: sample.end))
        return false
      }
      return true
    }
    var sessions = SleepSessionBuilder.sessions(
      from: valid, timeZone: context.timeZone, device: device, app: context.app
    )
    .filter { $0.start >= window.start && $0.start < window.end }
    for index in sessions.indices {
      sessions[index].biometrics = try await biometrics(for: sessions[index], context)
    }
    return sessions
  }

  /// Reads the session's span and summarises the readings taken while asleep. A session with no
  /// asleep interval has nothing to summarise and costs no query.
  private func biometrics(for session: SleepSessionRecord, _ context: SyncContext) async throws(PipelineStop)
    -> SleepBiometrics
  {
    guard session.stages.contains(where: \.stage.isAsleep) else { return SleepBiometrics() }
    guard !Task.isCancelled else { throw .cancelled }
    let samples: [BiometricSample]
    do {
      samples = try await context.health.biometricSamples(in: DateInterval(start: session.start, end: session.end))
    } catch .databaseInaccessible {
      throw .deferred
    } catch {
      throw .failed(.health(error))
    }
    return SleepBiometrics.summarize(samples, stages: session.stages)
  }

  /// Uploads in batches; an empty array sends nothing.
  private func send(_ records: [SleepSessionRecord], _ context: SyncContext) async throws(PipelineStop) {
    for chunk in records.chunks(ofCount: NocturneAPI.sleepUploadChunkSize) {
      guard !Task.isCancelled else { throw .cancelled }
      let batch = Array(chunk)
      do {
        try await context.withRetries { () throws(NocturneClientError) in
          try await context.client.uploadSleepSessions(batch)
        }
      } catch .cancelled {
        throw .cancelled
      } catch {
        throw .failed(.upload(error))
      }
    }
  }
}
