import Foundation
import Testing

@testable import NocturneSyncCore

@Suite struct RetryAfterTests {
  let now = Date(timeIntervalSince1970: 1_445_412_480)  // Wed, 21 Oct 2015 07:28:00 GMT

  @Test(arguments: [("120", 120.0), ("0", 0), (" 30 ", 30)])
  func parsesDeltaSeconds(header: String, expected: TimeInterval) {
    #expect(RetryAfter.seconds(from: header, now: now) == expected)
  }

  @Test func parsesFutureHTTPDateAsDelay() {
    #expect(RetryAfter.seconds(from: "Wed, 21 Oct 2015 07:30:00 GMT", now: now) == 120)
  }

  @Test func pastHTTPDateIsZero() {
    #expect(RetryAfter.seconds(from: "Wed, 21 Oct 2015 07:00:00 GMT", now: now) == 0)
  }

  @Test(arguments: ["", "soon", "-5", "1.5", "21 Oct 2015 07:30:00", "Wednesday, 21-Oct-15 07:30:00 GMT"])
  func rejectsEverythingElse(header: String) {
    #expect(RetryAfter.seconds(from: header, now: now) == nil)
  }
}
