import Foundation
import Testing

@testable import NocturneSyncCore

@Suite struct SleepDaysTests {
  let berlin = TimeZone(identifier: "Europe/Berlin")!
  let newYork = TimeZone(identifier: "America/New_York")!

  func local(_ text: String, in zone: TimeZone) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let parts = text.split(whereSeparator: { "-: ".contains($0) }).map { Int($0)! }
    return calendar.date(
      from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4]))!
  }

  @Test func daysRunFromLocalNoonToNoon() {
    #expect(
      SleepDays.dayStart(containing: local("2025-10-09 11:59", in: berlin), in: berlin)
        == local("2025-10-08 12:00", in: berlin))
    #expect(
      SleepDays.dayStart(containing: local("2025-10-09 12:00", in: berlin), in: berlin)
        == local("2025-10-09 12:00", in: berlin))
    #expect(
      SleepDays.dayStart(containing: local("2025-10-10 03:30", in: berlin), in: berlin)
        == local("2025-10-09 12:00", in: berlin))
    #expect(SleepDays.label(local("2025-10-09 12:00", in: berlin), in: berlin) == "2025-10-09")
  }

  @Test func boundariesStayOnTheWallClockAcrossDST() {
    // US DST ends 2024-11-03 at 02:00 (a 25-hour day); starts 2025-03-09 at 02:00 (23 hours).
    let before = local("2024-11-03 11:30", in: newYork)
    #expect(SleepDays.dayStart(containing: before, in: newYork) == local("2024-11-02 12:00", in: newYork))
    let after = local("2024-11-03 12:30", in: newYork)
    #expect(SleepDays.dayStart(containing: after, in: newYork) == local("2024-11-03 12:00", in: newYork))
    let next = SleepDays.dayStart(local("2024-11-02 12:00", in: newYork), offsetBy: 1, in: newYork)
    #expect(next == local("2024-11-03 12:00", in: newYork))
    #expect(next.timeIntervalSince(local("2024-11-02 12:00", in: newYork)) == 25 * 3600)
    let spring = SleepDays.dayStart(local("2025-03-08 12:00", in: newYork), offsetBy: 1, in: newYork)
    #expect(spring == local("2025-03-09 12:00", in: newYork))
    #expect(spring.timeIntervalSince(local("2025-03-08 12:00", in: newYork)) == 23 * 3600)
    #expect(SleepDays.dayStart(spring, offsetBy: -1, in: newYork) == local("2025-03-08 12:00", in: newYork))
  }

  @Test func theDayDependsOnTheZone() {
    let instant = local("2025-10-09 10:00", in: berlin)  // 04:00 in New York: still the 8th's day there
    #expect(SleepDays.label(SleepDays.dayStart(containing: instant, in: berlin), in: berlin) == "2025-10-08")
    #expect(SleepDays.label(SleepDays.dayStart(containing: instant, in: newYork), in: newYork) == "2025-10-08")
    let noonBerlin = local("2025-10-09 12:00", in: berlin)
    #expect(SleepDays.label(SleepDays.dayStart(containing: noonBerlin, in: berlin), in: berlin) == "2025-10-09")
    #expect(SleepDays.label(SleepDays.dayStart(containing: noonBerlin, in: newYork), in: newYork) == "2025-10-08")
  }
}

@Suite struct SleepSessionBuilderTests {
  let utc = EngineFixtures.utc
  /// 2025-10-08 22:00 UTC: bedtime in the sleep day 2025-10-08 (noon to noon).
  let bedtime = Date(timeIntervalSince1970: 1_759_960_800)
  let app = EngineFixtures.app

  func build(_ samples: [SleepSample], zone: TimeZone? = nil) -> [SleepSessionRecord] {
    SleepSessionBuilder.sessions(from: samples, timeZone: zone ?? utc, device: "Apple Health", app: app)
  }

  @Test func oneNightBecomesOneSessionNamedByItsDay() throws {
    let samples = EngineFixtures.night(from: bedtime)
    let sessions = build(samples.shuffled())
    let session = try #require(sessions.first)
    #expect(sessions.count == 1)
    #expect(session.originalID == "sleep-2025-10-08-0")
    #expect(session.start == bedtime)
    #expect(session.end == bedtime.addingTimeInterval(8 * 3600))
    #expect(session.kind == .overnight)
    #expect(session.isMainSleep)
    #expect(session.detection == .auto)
    #expect(session.timeZoneIdentifier == utc.identifier)
    #expect(session.device == "Apple Health")
    #expect(session.app == app)
    #expect(session.source == "Apple")
    #expect(session.stages.count == samples.count)
    #expect(session.stages.map(\.start) == session.stages.map(\.start).sorted())
    #expect(session.stages.filter { $0.stage == .inBed }.map(\.end) == [session.end])
  }

  @Test func totalsAreSummedPerStage() {
    // 16 half-hour Watch intervals cycling core, deep, REM, core, awake.
    let session = build(EngineFixtures.night(from: bedtime))[0]
    #expect(session.durationMs == 8 * 3600 * 1000)
    #expect(session.totalAwakeMs == 3 * 1800 * 1000)
    #expect(session.totalSleepMs == 13 * 1800 * 1000)
    #expect(session.deepSleepMs == 3 * 1800 * 1000)
    #expect(session.remSleepMs == 3 * 1800 * 1000)
    #expect(session.lightSleepMs == 7 * 1800 * 1000)
  }

  @Test func undifferentiatedSleepHasNoStageTotals() {
    let session = build(EngineFixtures.nap(at: bedtime))[0]
    #expect(session.totalSleepMs == 40 * 60 * 1000)
    #expect(session.deepSleepMs == nil && session.lightSleepMs == nil && session.remSleepMs == nil)
    #expect(session.totalAwakeMs == 0)
  }

  @Test func aGapLongerThanAnHourSplitsSessionsAndNapsFollowTheMain() {
    let napStart = bedtime.addingTimeInterval(-6 * 3600)  // 16:00, same sleep day
    let sessions = build(EngineFixtures.nap(at: napStart) + EngineFixtures.night(from: bedtime))
    #expect(sessions.map(\.originalID) == ["sleep-2025-10-08-0", "sleep-2025-10-08-1"])
    #expect(sessions.map(\.kind) == [.nap, .overnight])
    #expect(sessions.map(\.isMainSleep) == [false, true])
    #expect(sessions[0].start == napStart)
  }

  @Test func aGapOfAnHourOrLessJoinsSamples() throws {
    let first = EngineFixtures.nap(at: bedtime, minutes: 60)
    let second = EngineFixtures.nap(at: bedtime.addingTimeInterval(2 * 3600 + 1), minutes: 60)  // gap 1 h + 1 s
    let third = EngineFixtures.nap(at: bedtime.addingTimeInterval(4 * 3600 + 1), minutes: 60)  // gap exactly 1 h
    let sessions = build(first + second + third)
    #expect(sessions.map(\.start) == [bedtime, second[0].start])
    #expect(try #require(sessions.last).end == third[0].end)
  }

  @Test func sessionsAreNamedByTheDayOfTheirStart() {
    let afterNoon = bedtime.addingTimeInterval(13 * 3600 + 1800)  // 2025-10-09 11:30, still the 8th's day
    let sessions = build(EngineFixtures.night(from: bedtime) + EngineFixtures.nap(at: afterNoon))
    #expect(sessions.map(\.originalID) == ["sleep-2025-10-08-0", "sleep-2025-10-08-1"])
    let nextDay = build(
      EngineFixtures.night(from: bedtime) + EngineFixtures.nap(at: afterNoon.addingTimeInterval(1800)))
    #expect(nextDay.map(\.originalID) == ["sleep-2025-10-08-0", "sleep-2025-10-09-0"])
  }

  @Test func recordingZoneComesFromTheSamplesWhenPresent() {
    var samples = EngineFixtures.night(from: bedtime)
    samples[3].timeZoneIdentifier = "Europe/Berlin"
    #expect(build(samples)[0].timeZoneIdentifier == "Europe/Berlin")
    #expect(build(samples, zone: TimeZone(identifier: "Asia/Tokyo")!)[0].timeZoneIdentifier == "Europe/Berlin")
  }

  @Test func manualOnlyWhenEverySampleWasTyped() {
    #expect(build(EngineFixtures.night(from: bedtime, userEntered: true))[0].detection == .manual)
    var mixed = EngineFixtures.night(from: bedtime, userEntered: true)
    mixed[0].wasUserEntered = false
    #expect(build(mixed)[0].detection == .auto)
  }

  @Test func stagesMapToNocturneNames() {
    let pairs: [(SleepStage, SleepSessionRecord.Stage)] = [
      (.inBed, .inBed), (.asleepUnspecified, .asleep), (.awake, .awake), (.asleepCore, .light), (.asleepDeep, .deep),
      (.asleepREM, .rem), (.unknown, .unknown),
    ]
    for (stage, expected) in pairs { #expect(SleepSessionRecord.Stage(stage) == expected) }
    #expect(SleepSessionRecord.Stage.light.isAsleep && !SleepSessionRecord.Stage.inBed.isAsleep)
  }

  @Test func digestChangesWithContentButNotWithSampleIdentity() {
    let night = EngineFixtures.night(from: bedtime)
    let original = build(night)[0].contentDigest
    var renamed = night
    renamed[2].id = UUID()
    #expect(build(renamed)[0].contentDigest == original)
    var extended = night
    extended[0].end = extended[0].end.addingTimeInterval(60)
    #expect(build(extended)[0].contentDigest != original)
    #expect(
      build(
        night.map {
          var s = $0
          s.wasUserEntered = true
          return s
        })[0].contentDigest != original)
    #expect(original == FNV1a.hexDigest(of: "x") || original.count <= 16)
  }
}
