import Foundation

@testable import NocturneSyncCore

enum Fixtures {
  /// 2024-07-01 10:00:00.250 UTC.
  static let instant = Date(timeIntervalSince1970: 1_719_828_000.25)

  static func heartRate(index: Int = 0) -> HeartRateRecord {
    HeartRateRecord(
      timestamp: instant.addingTimeInterval(TimeInterval(index)),
      utcOffsetMinutes: 120,
      bpm: 72,
      device: "Watch7,1",
      syncIdentifier: "6BA7B810-9DAD-11D1-80B4-\(String(format: "%012X", index))"
    )
  }

  static func heartRates(_ count: Int) -> [HeartRateRecord] {
    (0..<count).map { heartRate(index: $0) }
  }

  static func stepCount(index: Int = 0) -> StepCountRecord {
    let bucket = StepBucket(containing: instant.addingTimeInterval(TimeInterval(index * 300)))
    return StepCountRecord(
      timestamp: bucket.start,
      utcOffsetMinutes: -270,
      metric: 42,
      device: "iPhone16,2",
      syncIdentifier: bucket.syncIdentifier
    )
  }

  static func stepCounts(_ count: Int) -> [StepCountRecord] {
    (0..<count).map { stepCount(index: $0) }
  }

  /// A 90-minute session starting at `instant`, with one in-bed interval and three stages.
  static func sleepSession(index: Int = 0) -> SleepSessionRecord {
    let start = instant.addingTimeInterval(TimeInterval(index) * 86_400)
    let end = start.addingTimeInterval(5400)
    return SleepSessionRecord(
      originalID: "sleep-2024-07-0\(index + 1)-0",
      start: start,
      end: end,
      timeZoneIdentifier: "Europe/Berlin",
      kind: .overnight,
      isMainSleep: true,
      detection: .auto,
      device: "Apple Health",
      app: "NocturneSync",
      stages: [
        .init(start: start, end: end, stage: .inBed),
        .init(start: start, end: start.addingTimeInterval(1800), stage: .light),
        .init(start: start.addingTimeInterval(1800), end: start.addingTimeInterval(3600), stage: .deep),
        .init(start: start.addingTimeInterval(3600), end: end, stage: .awake),
      ])
  }

  static func sleepSessions(_ count: Int) -> [SleepSessionRecord] {
    (0..<count).map { sleepSession(index: $0) }
  }
}

/// Runs `body` and returns the typed error it threw, or nil if it succeeded.
func thrownError<T>(_ body: () async throws(NocturneClientError) -> T) async -> NocturneClientError? {
  do {
    _ = try await body()
    return nil
  } catch {
    return error
  }
}
