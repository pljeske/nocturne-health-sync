import Foundation
import Testing

@testable import NocturneSyncCore

@Suite struct StepWindowsTests {
  @Test func lookbackStartsOnABucketBoundaryAndEndsNow() {
    let now = Date(timeIntervalSince1970: 1_760_000_000)  // 08:53:20 UTC
    let window = StepWindows.lookback(now: now, hours: 24, bucketSeconds: 300)
    #expect(window.start == Date(timeIntervalSince1970: 1_759_913_400))  // 08:50:00 the day before
    #expect(window.end == now)
    #expect(StepBucket(startingAt: window.start) != nil)
  }

  @Test func alignedNowGivesExactlyTwentyFourHours() {
    let now = Date(timeIntervalSince1970: 1_759_999_800)
    #expect(StepWindows.lookback(now: now, hours: 24, bucketSeconds: 300).duration == 86_400)
  }

  @Test func initialWatermarkIsAlignedNinetyDaysBack() {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let watermark = StepWindows.initialWatermark(now: now, backfillDays: 90, bucketSeconds: 300)
    #expect(StepBucket(startingAt: watermark) != nil)
    #expect(now.timeIntervalSince(watermark) >= 90 * 86_400)
    #expect(now.timeIntervalSince(watermark) < 90 * 86_400 + 300)
  }

  /// Crosses the European DST end (27 Oct), a month end (31 Oct) and the US DST end (3 Nov 2024).
  @Test func slicesAreContiguousFixedLengthAndAlignedAcrossDSTAndMonthEnds() throws {
    let start = Date(timeIntervalSince1970: 1_729_814_400)  // 2024-10-25 00:00 UTC
    let limit = Date(timeIntervalSince1970: 1_730_617_200)  // 2024-11-03 07:00 UTC
    var slices: [DateInterval] = []
    var watermark = start
    while let slice = StepWindows.nextSlice(watermark: watermark, limit: limit, sliceSeconds: 86_400) {
      slices.append(slice)
      watermark = slice.end
    }
    #expect(slices.count == 10)
    #expect(slices.first?.start == start)
    #expect(slices.last?.end == limit)
    #expect(slices.dropLast().allSatisfy { $0.duration == 86_400 })
    #expect(slices.last?.duration == TimeInterval(7 * 3600))
    #expect(zip(slices, slices.dropFirst()).allSatisfy { $0.end == $1.start })
    #expect(slices.allSatisfy { StepBucket(startingAt: $0.start) != nil })
    let buckets = slices.flatMap { StepBucket.buckets(overlapping: $0) }
    #expect(Set(buckets).count == buckets.count)
    #expect(buckets.count == Int(limit.timeIntervalSince(start)) / 300)
  }

  @Test func noSliceOnceCaughtUp() {
    let limit = Date(timeIntervalSince1970: 1_730_617_200)
    #expect(StepWindows.nextSlice(watermark: limit, limit: limit, sliceSeconds: 86_400) == nil)
    #expect(StepWindows.nextSlice(watermark: limit.addingTimeInterval(300), limit: limit, sliceSeconds: 86_400) == nil)
  }
}
