import Foundation
import Testing

@testable import NocturneSyncCore

@Suite struct SleepBiometricsTests {
  /// Bedtime of the fixture night. Watch intervals are 30 min: core, deep, REM, core, awake, repeating,
  /// so [2 h, 2.5 h) is awake; an iPhone in-bed band covers the whole 8 h.
  let bedtime = Date(timeIntervalSince1970: 1_759_960_800)

  var stages: [SleepSessionRecord.StageInterval] {
    SleepSessionBuilder.sessions(
      from: EngineFixtures.night(from: bedtime), timeZone: EngineFixtures.utc, device: "Apple Health",
      app: EngineFixtures.app)[0].stages
  }

  func at(_ minutes: Double, _ kind: BiometricSample.Kind, _ value: Double) -> BiometricSample {
    BiometricSample(kind: kind, date: bedtime.addingTimeInterval(minutes * 60), value: value)
  }

  @Test func averagesAndMinimumOverAsleepReadings() {
    let summary = SleepBiometrics.summarize(
      [
        at(10, .heartRate, 58), at(40, .heartRate, 52), at(70, .heartRate, 55.5),
        at(15, .heartRateVariability, 40), at(95, .heartRateVariability, 61),
        at(20, .respiratoryRate, 14), at(100, .respiratoryRate, 15),
        at(25, .oxygenSaturation, 0.95), at(105, .oxygenSaturation, 0.98),
      ], stages: stages)
    #expect(summary.averageHeartRate == 55.2)
    #expect(summary.minimumHeartRate == 52)
    #expect(summary.averageHRV == 50.5)
    #expect(summary.averageRespiratoryRate == 14.5)
    #expect(summary.averageOxygenSaturation == 96.5)
  }

  @Test func readingsWhileAwakeOrOutsideTheSessionDoNotCount() {
    let summary = SleepBiometrics.summarize(
      [
        at(10, .heartRate, 50),
        at(130, .heartRate, 90),  // awake interval [120, 150)
        at(-30, .heartRate, 95),  // before bedtime
        at(480, .heartRate, 99),  // the session end is exclusive
        at(150, .heartRate, 60),  // start of the next asleep interval
      ], stages: stages)
    #expect(summary.averageHeartRate == 55)
    #expect(summary.minimumHeartRate == 50)
  }

  @Test func inBedOnlySessionsHaveNoSummary() {
    let inBed = [
      SleepSessionRecord.StageInterval(start: bedtime, end: bedtime.addingTimeInterval(8 * 3600), stage: .inBed)
    ]
    let summary = SleepBiometrics.summarize([at(10, .heartRate, 55)], stages: inBed)
    #expect(summary.isEmpty)
  }

  @Test func missingKindsStayNil() {
    let summary = SleepBiometrics.summarize([at(10, .heartRate, 55)], stages: stages)
    #expect(summary.averageHeartRate == 55)
    #expect(
      summary.averageHRV == nil && summary.averageRespiratoryRate == nil && summary.averageOxygenSaturation == nil)
  }

  @Test func overlappingAsleepIntervalsCountAReadingOnce() {
    let start = bedtime
    let end = bedtime.addingTimeInterval(3600)
    let overlapping: [SleepSessionRecord.StageInterval] = [
      .init(start: start, end: end, stage: .asleep), .init(start: start, end: end, stage: .light),
    ]
    let summary = SleepBiometrics.summarize([at(10, .heartRate, 50), at(20, .heartRate, 60)], stages: overlapping)
    #expect(summary.averageHeartRate == 55)
  }

  @Test func impossibleReadingsAreSkipped() {
    let summary = SleepBiometrics.summarize(
      [
        at(10, .heartRate, .nan), at(11, .heartRate, -1), at(12, .heartRate, .infinity), at(13, .heartRate, 60),
        at(14, .oxygenSaturation, 1.2), at(15, .oxygenSaturation, 0.97),
      ], stages: stages)
    #expect(summary.averageHeartRate == 60)
    #expect(summary.minimumHeartRate == 60)
    #expect(summary.averageOxygenSaturation == 97)
  }

  @Test func digestFollowsTheSummary() {
    var record = SleepSessionBuilder.sessions(
      from: EngineFixtures.night(from: bedtime), timeZone: EngineFixtures.utc, device: "Apple Health",
      app: EngineFixtures.app)[0]
    let bare = record.contentDigest
    record.biometrics = SleepBiometrics(averageHRV: 48.2)
    let withHRV = record.contentDigest
    #expect(withHRV != bare)
    record.biometrics = SleepBiometrics(averageRespiratoryRate: 48.2)
    #expect(record.contentDigest != withHRV)
  }
}
