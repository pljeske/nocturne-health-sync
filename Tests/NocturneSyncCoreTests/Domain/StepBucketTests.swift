import Foundation
import Testing

@testable import NocturneSyncCore

@Suite struct StepBucketTests {
  // 2023-11-14 22:13:20 UTC
  let instant = Date(timeIntervalSince1970: 1_700_000_000)

  @Test func alignsToEpochMultiples() {
    let bucket = StepBucket(containing: instant)
    #expect(bucket.startUnixSeconds == 1_699_999_800)
    #expect(bucket.bucketSeconds == 300)
    #expect(bucket.syncIdentifier == "steps-1699999800-300")
    #expect(bucket.interval.contains(instant))
  }

  @Test func exactBoundaryBelongsToTheBucketItStarts() {
    let bucket = StepBucket(containing: Date(timeIntervalSince1970: 1_699_999_800))
    #expect(bucket.startUnixSeconds == 1_699_999_800)
    let before = StepBucket(containing: Date(timeIntervalSince1970: 1_699_999_799.999))
    #expect(before.startUnixSeconds == 1_699_999_500)
  }

  @Test func identifierIgnoresSubSecondFractions() {
    let a = StepBucket(containing: Date(timeIntervalSince1970: 1_700_000_000.0))
    let b = StepBucket(containing: Date(timeIntervalSince1970: 1_700_000_000.734))
    #expect(a == b)
    #expect(a.syncIdentifier == b.syncIdentifier)
  }

  @Test func alignmentIsEpochBasedNotLocal() throws {
    // Asia/Kolkata is UTC+5:30, so local midnight is 30 min off any epoch-aligned hour.
    let kolkata = try #require(TimeZone(identifier: "Asia/Kolkata"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = kolkata
    let localMidnight = try #require(
      calendar.date(from: DateComponents(year: 2024, month: 3, day: 10, hour: 0, minute: 2)))
    let bucket = StepBucket(containing: localMidnight)
    #expect(bucket.startUnixSeconds % 300 == 0)
    #expect(bucket.start <= localMidnight)
    #expect(localMidnight < bucket.interval.end)
    // 00:02 IST is 18:32 UTC of the previous day; bucket starts 18:30 UTC.
    #expect(bucket.startUnixSeconds == 1_710_009_000)
  }

  @Test func enumerationCoversHalfOpenWindow() {
    let start = Date(timeIntervalSince1970: 1_700_000_100)  // exactly on a bucket boundary
    let end = Date(timeIntervalSince1970: 1_700_000_700)
    let buckets = StepBucket.buckets(overlapping: DateInterval(start: start, end: end))
    #expect(buckets.map(\.startUnixSeconds) == [1_700_000_100, 1_700_000_400])
  }

  @Test func enumerationIncludesPartialBucketsAtBothEnds() {
    let start = Date(timeIntervalSince1970: 1_700_000_150)
    let end = Date(timeIntervalSince1970: 1_700_000_701)
    let buckets = StepBucket.buckets(overlapping: DateInterval(start: start, end: end))
    #expect(buckets.map(\.startUnixSeconds) == [1_700_000_100, 1_700_000_400, 1_700_000_700])
  }

  @Test func emptyWindowYieldsNoBuckets() {
    let start = Date(timeIntervalSince1970: 1_700_000_150)
    #expect(StepBucket.buckets(overlapping: DateInterval(start: start, end: start)).isEmpty)
  }

  @Test(arguments: [
    (DateComponents(year: 2024, month: 3, day: 10), 23 * 12),  // spring forward, 23 h local day
    (DateComponents(year: 2024, month: 11, day: 3), 25 * 12),  // fall back, 25 h local day
    (DateComponents(year: 2024, month: 6, day: 1), 24 * 12),
  ])
  func localDayAcrossDSTIsCoveredExactly(day: DateComponents, expectedBuckets: Int) throws {
    let newYork = try #require(TimeZone(identifier: "America/New_York"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = newYork
    let start = try #require(calendar.date(from: day))
    let end = try #require(calendar.date(byAdding: .day, value: 1, to: start))
    let buckets = StepBucket.buckets(overlapping: DateInterval(start: start, end: end))
    #expect(buckets.count == expectedBuckets)
    #expect(buckets.first?.start == start)
    #expect(buckets.last?.interval.end == end)
    for (a, b) in zip(buckets, buckets.dropFirst()) {
      #expect(a.interval.end == b.start)
    }
  }
}
