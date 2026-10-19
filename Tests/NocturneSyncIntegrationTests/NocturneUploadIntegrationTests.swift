import Foundation
import NocturneSyncCore
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Uploads synthetic records to a development Nocturne and reads them back. Never point this at an
/// instance with real data: it writes records with device "integration-test".
@Suite(.serialized, .enabled(if: IntegrationEnvironment.isConfigured, "set NOCTURNE_INTEGRATION_URL to run"))
struct NocturneUploadIntegrationTests {
  let app = "NocturneSync integration-test"

  func client() async throws -> (HTTPNocturneClient, String) {
    let token = try await IntegrationEnvironment.token()
    return (
      HTTPNocturneClient(
        baseURL: try IntegrationEnvironment.requireBaseURL(), transport: BearerTransport(token: token)), token
    )
  }

  /// A whole-second instant an hour ago.
  func recentInstant() -> Date {
    Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded(.down))
  }

  @Test func heartRateReuploadUpdatesInPlace() async throws {
    let (client, token) = try await client()
    let start = recentInstant()
    let ids = (0..<3).map { _ in UUID().uuidString }
    let first = ids.enumerated().map { index, id in
      HeartRateRecord(
        timestamp: start.addingTimeInterval(TimeInterval(index)), utcOffsetMinutes: 120, bpm: 60 + index,
        device: "integration-test", app: app, syncIdentifier: id)
    }
    try await client.uploadHeartRates(first)
    try await client.uploadHeartRates(
      first.map { record in
        var updated = record
        updated.bpm += 10
        return updated
      })

    let stored = try await IntegrationEnvironment.fetch(
      StoredHeartRate.self, path: "api/v4/HeartRate", around: start, token: token
    ).filter { ids.contains($0.syncIdentifier ?? "") }

    #expect(stored.count == 3, "one row per syncIdentifier after a re-upload")
    #expect(Set(stored.map(\.bpm)) == [70, 71, 72])
    #expect(stored.allSatisfy { $0.dataSource == NocturneConstants.dataSource })
    #expect(stored.allSatisfy { $0.enteredBy == app && $0.device == "integration-test" && $0.utcOffset == 120 })
  }

  @Test func moreThanOneRequestWorthIsChunkedAndStored() async throws {
    let (client, token) = try await client()
    let start = recentInstant()
    let records = (0..<1200).map { index in
      HeartRateRecord(
        timestamp: start.addingTimeInterval(TimeInterval(index)), utcOffsetMinutes: 0, bpm: 80,
        device: "integration-test", app: app, syncIdentifier: UUID().uuidString)
    }
    try await client.uploadHeartRates(records)

    let ids = Set(records.map(\.syncIdentifier))
    let stored = try await IntegrationEnvironment.fetch(
      StoredHeartRate.self, path: "api/v4/HeartRate", around: start, token: token
    ).filter { ids.contains($0.syncIdentifier ?? "") }
    #expect(stored.count == 1200)
  }

  @Test func stepBucketReuploadUpdatesInPlace() async throws {
    let (client, token) = try await client()
    let buckets = StepBucket.buckets(
      overlapping: DateInterval(start: recentInstant().addingTimeInterval(-7200), duration: 900))
    let metric = Int.random(in: 100...900)
    let first = buckets.map { bucket in
      StepCountRecord(
        timestamp: bucket.start, utcOffsetMinutes: -300, metric: metric, device: NocturneConstants.mergedDevice,
        app: app, syncIdentifier: bucket.syncIdentifier)
    }
    try await client.uploadStepCounts(first)
    try await client.uploadStepCounts(
      first.map { record in
        var updated = record
        updated.metric += 1
        return updated
      })

    let ids = Set(buckets.map(\.syncIdentifier))
    let stored = try await IntegrationEnvironment.fetch(
      StoredStepCount.self, path: "api/v4/StepCount", around: buckets[0].start, token: token
    ).filter { ids.contains($0.syncIdentifier ?? "") }

    #expect(stored.count == buckets.count, "one row per bucket identifier")
    #expect(stored.allSatisfy { $0.metric == metric + 1 && $0.source == 0 && $0.utcOffset == -300 })
    #expect(stored.allSatisfy { $0.dataSource == NocturneConstants.dataSource && $0.enteredBy == app })
  }

  @Test func sleepSessionReuploadUpdatesInPlace() async throws {
    let (client, token) = try await client()
    let start = recentInstant().addingTimeInterval(-8 * 3600)
    // A random day label keeps repeated runs from colliding with each other's sessions.
    let day = String(format: "2000-%02d-%02d", Int.random(in: 1...12), Int.random(in: 1...28))
    func session(hours: Double) -> SleepSessionRecord {
      let end = start.addingTimeInterval(hours * 3600)
      return SleepSessionRecord(
        originalID: "sleep-\(day)-0", start: start, end: end, timeZoneIdentifier: "Europe/Berlin", kind: .overnight,
        isMainSleep: true, detection: .auto, device: "integration-test", app: app,
        stages: [
          .init(start: start, end: end, stage: .inBed),
          .init(start: start, end: start.addingTimeInterval(3600), stage: .light),
          .init(start: start.addingTimeInterval(3600), end: end, stage: .deep),
        ])
    }
    try await client.uploadSleepSessions([session(hours: 6)])
    try await client.uploadSleepSessions([session(hours: 7)])

    let stored = try await IntegrationEnvironment.fetchSleepSessions(around: start, token: token)
      .filter { $0.originalId == "sleep-\(day)-0" }

    #expect(stored.count == 1, "one row per (source, originalId) after a re-upload")
    #expect(stored.first?.source == NocturneConstants.sleepSource)
    #expect(stored.first?.type == "Overnight")
    #expect(stored.first?.startMills == Int(start.timeIntervalSince1970 * 1000))
    #expect(stored.first?.endMills == Int(start.addingTimeInterval(7 * 3600).timeIntervalSince1970 * 1000))
    #expect(stored.first?.totalSleepMs == 7 * 3600 * 1000)
    #expect(stored.first?.sourceApp == app && stored.first?.sourceDevice == "integration-test")
  }

  @Test func invalidTokenIsUnauthorized() async throws {
    let client = HTTPNocturneClient(
      baseURL: try IntegrationEnvironment.requireBaseURL(), transport: BearerTransport(token: "not-a-token"))
    do {
      try await client.uploadHeartRates([
        HeartRateRecord(
          timestamp: recentInstant(), utcOffsetMinutes: 0, bpm: 60, device: "integration-test", app: app,
          syncIdentifier: UUID().uuidString)
      ])
      Issue.record("upload with an invalid token succeeded")
    } catch {
      guard case .unauthorized = error else {
        Issue.record("expected .unauthorized, got \(error)")
        return
      }
    }
  }
}
