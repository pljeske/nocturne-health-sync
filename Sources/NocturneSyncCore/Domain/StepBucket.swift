import Foundation

/// A fixed-length step bucket aligned to the Unix epoch (not to local time, so it is stable across
/// time zone changes and DST transitions).
public struct StepBucket: Sendable, Hashable {
  public let startUnixSeconds: Int
  public let bucketSeconds: Int

  /// The bucket that contains `date`.
  public init(containing date: Date, bucketSeconds: Int = NocturneConstants.stepBucketSeconds) {
    precondition(bucketSeconds > 0, "bucketSeconds must be positive")
    let seconds = (date.timeIntervalSince1970 / Double(bucketSeconds)).rounded(.down) * Double(bucketSeconds)
    self.init(startUnixSeconds: Int(seconds), bucketSeconds: bucketSeconds)
  }

  init(startUnixSeconds: Int, bucketSeconds: Int) {
    self.startUnixSeconds = startUnixSeconds
    self.bucketSeconds = bucketSeconds
  }

  public var start: Date { Date(timeIntervalSince1970: TimeInterval(startUnixSeconds)) }

  public var interval: DateInterval { DateInterval(start: start, duration: TimeInterval(bucketSeconds)) }

  /// `steps-<bucketStartUnixSeconds>-<bucketSeconds>`. Server-side identity of the bucket.
  public var syncIdentifier: String { "steps-\(startUnixSeconds)-\(bucketSeconds)" }

  public var next: StepBucket {
    StepBucket(startUnixSeconds: startUnixSeconds + bucketSeconds, bucketSeconds: bucketSeconds)
  }

  /// Every bucket that overlaps the half-open window `[interval.start, interval.end)`, in order.
  /// Empty when the window is empty.
  public static func buckets(
    overlapping interval: DateInterval,
    bucketSeconds: Int = NocturneConstants.stepBucketSeconds
  ) -> [StepBucket] {
    guard interval.duration > 0 else { return [] }
    var result: [StepBucket] = []
    var bucket = StepBucket(containing: interval.start, bucketSeconds: bucketSeconds)
    while bucket.start < interval.end {
      result.append(bucket)
      bucket = bucket.next
    }
    return result
  }
}
