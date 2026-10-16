import Foundation
import Testing

@testable import NocturneSyncCore

@Suite struct HeartRateMappingTests {
  let berlin = TimeZone(identifier: "Europe/Berlin")!
  let id = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
  // 2024-07-01 10:00:00 UTC, CEST (+02:00).
  let date = Date(timeIntervalSince1970: 1_719_828_000)

  @Test func mapsSampleToRecord() throws {
    let sample = HeartRateSample(id: id, date: date, beatsPerMinute: 72.4, device: "Apple Watch")
    let record = try HeartRateMapper.record(from: sample, deviceTimeZone: berlin, app: "NocturneSync 0.1.0")
    #expect(record.timestamp == date)
    #expect(record.utcOffsetMinutes == 120)
    #expect(record.bpm == 72)
    #expect(record.accuracy == 0)
    #expect(record.device == "Apple Watch")
    #expect(record.app == "NocturneSync 0.1.0")
    #expect(record.dataSource == "apple-health-ios")
    #expect(record.syncIdentifier == "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")
  }

  @Test func sampleTimeZoneWinsOverDeviceZone() throws {
    let sample = HeartRateSample(
      id: id, date: date, beatsPerMinute: 60, timeZoneIdentifier: "America/Los_Angeles", device: "Apple Watch")
    let record = try HeartRateMapper.record(from: sample, deviceTimeZone: berlin, app: "NocturneSync 0.1.0")
    #expect(record.utcOffsetMinutes == -420)
  }

  @Test(arguments: [(72.5, 73), (72.49, 72), (71.5, 72), (0.0, 0), (0.4, 0), (199.999, 200)])
  func roundsHalfAwayFromZero(input: Double, expected: Int) throws {
    #expect(try HeartRateMapper.roundedBPM(input) == expected)
  }

  @Test(arguments: [Double.nan, .infinity, -.infinity, -1, -0.6, 1e300])
  func rejectsImpossibleValues(input: Double) {
    #expect(throws: MappingError.self) {
      try HeartRateMapper.roundedBPM(input)
    }
  }

  @Test func appIdentifierCarriesTheMarketingVersion() {
    #expect(NocturneConstants.appIdentifier(version: "1.2.3") == "NocturneSync 1.2.3")
  }

  @Test func errorCarriesTheOffendingValue() {
    #expect(throws: MappingError.invalidHeartRate(-0.6)) {
      try HeartRateMapper.roundedBPM(-0.6)
    }
  }
}

@Suite struct StepCountMappingTests {
  let newYork = TimeZone(identifier: "America/New_York")!

  @Test func mapsBucketTotalToRecord() throws {
    // Bucket starting 2024-11-03 05:30:00 UTC = 01:30 EDT, 30 min before fall-back.
    let bucket = StepBucket(containing: Date(timeIntervalSince1970: 1_730_611_800))
    let record = try StepCountMapper.record(
      from: StepBucketTotal(bucket: bucket, steps: 123.4), deviceTimeZone: newYork, device: "iPhone",
      app: "NocturneSync 0.1.0")
    #expect(record.timestamp == bucket.start)
    #expect(record.utcOffsetMinutes == -240)
    #expect(record.metric == 123)
    #expect(record.source == 0)
    #expect(record.device == "iPhone")
    #expect(record.app == "NocturneSync 0.1.0")
    #expect(record.syncIdentifier == "steps-1730611800-300")
  }

  @Test func offsetChangesAcrossFallBack() throws {
    // 2024-11-03 06:00:00 UTC = 01:00 EST, after the clocks went back.
    let bucket = StepBucket(containing: Date(timeIntervalSince1970: 1_730_613_600))
    let record = try StepCountMapper.record(
      from: StepBucketTotal(bucket: bucket, steps: 1), deviceTimeZone: newYork, device: "iPhone",
      app: "NocturneSync 0.1.0")
    #expect(record.utcOffsetMinutes == -300)
  }

  @Test func zeroTotalMapsToZero() throws {
    let bucket = StepBucket(containing: Date(timeIntervalSince1970: 1_700_000_000))
    let record = try StepCountMapper.record(
      from: StepBucketTotal(bucket: bucket, steps: 0), deviceTimeZone: newYork, device: "iPhone",
      app: "NocturneSync 0.1.0")
    #expect(record.metric == 0)
  }

  @Test(arguments: [Double.nan, .infinity, -1, 1e300])
  func rejectsImpossibleValues(input: Double) {
    #expect(throws: MappingError.self) {
      try StepCountMapper.roundedSteps(input)
    }
  }

  @Test func errorCarriesTheOffendingValue() {
    #expect(throws: MappingError.invalidStepCount(-1)) {
      try StepCountMapper.roundedSteps(-1)
    }
  }
}
