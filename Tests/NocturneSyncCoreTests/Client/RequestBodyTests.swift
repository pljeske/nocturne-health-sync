import Foundation
import Testing

@testable import NocturneSyncCore

@Suite struct RequestBodyTests {
  @Test func heartRateJSONMatchesContract() throws {
    let data = try RequestEncoder.encode([HeartRateRequestBody(Fixtures.heartRate())])
    let expected = """
      [{"accuracy":0,"app":"NocturneSync","bpm":72,"dataSource":"apple-health-ios","device":"Watch7,1",\
      "syncIdentifier":"6BA7B810-9DAD-11D1-80B4-000000000000","timestamp":"2024-07-01T12:00:00.250+02:00",\
      "utcOffset":120}]
      """
    #expect(String(decoding: data, as: UTF8.self) == expected)
  }

  @Test func stepCountJSONMatchesContract() throws {
    let data = try RequestEncoder.encode([StepCountRequestBody(Fixtures.stepCount())])
    // Bucket start 10:00:00 UTC, written in the record's -04:30 offset.
    let expected = """
      [{"app":"NocturneSync","dataSource":"apple-health-ios","device":"iPhone16,2","metric":42,"source":0,\
      "syncIdentifier":"steps-1719828000-300","timestamp":"2024-07-01T05:30:00.000-04:30","utcOffset":-270}]
      """
    #expect(String(decoding: data, as: UTF8.self) == expected)
  }

  @Test func sleepSessionJSONMatchesContract() throws {
    let data = try RequestEncoder.encode([SleepSessionRequestBody(Fixtures.sleepSession())])
    let expected = """
      [{"deepSleepMs":1800000,"detectionMethod":"Auto","durationMs":5400000,"endTime":"2024-07-01T11:30:00.250Z",\
      "isMainSleep":true,"lightSleepMs":1800000,"originalId":"sleep-2024-07-01-0","remSleepMs":0,"source":"Apple",\
      "sourceApp":"NocturneSync","sourceDevice":"Apple Health","stages":[\
      {"endTime":"2024-07-01T11:30:00.250Z","ordinal":0,"stage":"InBed","startTime":"2024-07-01T10:00:00.250Z"},\
      {"endTime":"2024-07-01T10:30:00.250Z","ordinal":1,"stage":"Light","startTime":"2024-07-01T10:00:00.250Z"},\
      {"endTime":"2024-07-01T11:00:00.250Z","ordinal":2,"stage":"Deep","startTime":"2024-07-01T10:30:00.250Z"},\
      {"endTime":"2024-07-01T11:30:00.250Z","ordinal":3,"stage":"Awake","startTime":"2024-07-01T11:00:00.250Z"}],\
      "startTime":"2024-07-01T10:00:00.250Z","timezone":"Europe/Berlin","totalAwakeMs":1800000,\
      "totalSleepMs":3600000,"type":"Overnight"}]
      """
    #expect(String(decoding: data, as: UTF8.self) == expected)
  }

  @Test func undifferentiatedSleepOmitsStageTotals() throws {
    var record = Fixtures.sleepSession()
    record.stages = [.init(start: record.start, end: record.end, stage: .asleep)]
    let json = String(decoding: try RequestEncoder.encode([SleepSessionRequestBody(record)]), as: UTF8.self)
    #expect(!json.contains("deepSleepMs") && !json.contains("lightSleepMs") && !json.contains("remSleepMs"))
    #expect(json.contains("\"totalSleepMs\":5400000"))
  }

  @Test(arguments: [
    (0, "2024-07-01T10:00:00.250Z"),
    (60, "2024-07-01T11:00:00.250+01:00"),
    (-420, "2024-07-01T03:00:00.250-07:00"),
    (345, "2024-07-01T15:45:00.250+05:45"),
    (780, "2024-07-01T23:00:00.250+13:00"),
  ])
  func timestampIsWrittenInRecordOffset(offsetMinutes: Int, expected: String) {
    #expect(ISO8601Timestamp.string(Fixtures.instant, utcOffsetMinutes: offsetMinutes) == expected)
  }

  @Test func timestampRoundTripsToTheSameInstant() throws {
    let text = ISO8601Timestamp.string(Fixtures.instant, utcOffsetMinutes: -270)
    let parsed = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)
    #expect(abs(parsed.timeIntervalSince(Fixtures.instant)) < 0.001)
  }

  @Test func timestampCrossesMidnightWithOffset() {
    // 2024-07-01 23:30 UTC is already 2024-07-02 in Berlin.
    let late = Date(timeIntervalSince1970: 1_719_876_600)
    #expect(ISO8601Timestamp.string(late, utcOffsetMinutes: 120) == "2024-07-02T01:30:00.000+02:00")
  }
}
