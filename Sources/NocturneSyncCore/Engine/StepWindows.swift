import Foundation

/// Window arithmetic for the steps pipeline. Every boundary is an epoch-aligned bucket start and every
/// length is a whole number of buckets, so local time, DST and month lengths never enter: a "day"
/// slice is 86 400 seconds, not a calendar day.
enum StepWindows {
  /// `[floor(now - hours), now)`. The bucket containing `now` is included while it is still filling;
  /// the next run re-uploads it with its final total.
  static func lookback(now: Date, hours: Int, bucketSeconds: Int) -> DateInterval {
    let start = StepBucket(
      containing: now.addingTimeInterval(-TimeInterval(hours) * 3600), bucketSeconds: bucketSeconds)
    return DateInterval(start: start.start, end: max(start.start, now))
  }

  /// `floor(now - days)`: where the step backfill starts on the first run.
  static func initialWatermark(now: Date, backfillDays: Int, bucketSeconds: Int) -> Date {
    StepBucket(containing: now.addingTimeInterval(-TimeInterval(backfillDays) * 86_400), bucketSeconds: bucketSeconds)
      .start
  }

  /// The next backfill slice `[watermark, min(watermark + sliceSeconds, limit))`, or nil once the
  /// watermark has reached `limit`.
  static func nextSlice(watermark: Date, limit: Date, sliceSeconds: Int) -> DateInterval? {
    guard watermark < limit else { return nil }
    let end = min(watermark.addingTimeInterval(TimeInterval(sliceSeconds)), limit)
    return DateInterval(start: watermark, end: end)
  }
}
