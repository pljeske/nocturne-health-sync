import Foundation
import Testing

@testable import NocturneSyncCore

@Suite struct UTCOffsetResolverTests {
  let utc = TimeZone(identifier: "UTC")!

  // America/New_York switches from EST (-05:00) to EDT (-04:00) at 2024-03-10 07:00:00 UTC.
  let beforeSpringForward = Date(timeIntervalSince1970: 1_710_054_000 - 1)
  let atSpringForward = Date(timeIntervalSince1970: 1_710_054_000)

  @Test func usesSampleTimeZoneWhenPresent() {
    let offset = UTCOffsetResolver.offsetMinutes(
      timeZoneIdentifier: "Asia/Kolkata", fallback: utc, at: atSpringForward)
    #expect(offset == 330)
  }

  @Test func fallsBackToDeviceZoneWhenAbsent() throws {
    let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
    let offset = UTCOffsetResolver.offsetMinutes(timeZoneIdentifier: nil, fallback: berlin, at: atSpringForward)
    #expect(offset == 60)
  }

  @Test func fallsBackToDeviceZoneWhenIdentifierIsUnknown() throws {
    let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
    let offset = UTCOffsetResolver.offsetMinutes(
      timeZoneIdentifier: "Not/AZone", fallback: berlin, at: atSpringForward)
    #expect(offset == 60)
  }

  @Test func appliesDSTAtTheSampleInstant() {
    let before = UTCOffsetResolver.offsetMinutes(
      timeZoneIdentifier: "America/New_York", fallback: utc, at: beforeSpringForward)
    let after = UTCOffsetResolver.offsetMinutes(
      timeZoneIdentifier: "America/New_York", fallback: utc, at: atSpringForward)
    #expect(before == -300)
    #expect(after == -240)
  }
}
