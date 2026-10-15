import Foundation

/// A heart rate sample as read from Health, before mapping. Produced by `HealthSource`.
public struct HeartRateSample: Sendable, Hashable {
  /// `HKObject.uuid`; becomes the record's `syncIdentifier`.
  public var id: UUID
  /// `HKSample.startDate`.
  public var date: Date
  /// Value in count/min, as HealthKit stores it.
  public var beatsPerMinute: Double
  /// `HKMetadataKeyTimeZone`, when the recording app set it.
  public var timeZoneIdentifier: String?
  /// Name of the recording device or source.
  public var device: String

  public init(id: UUID, date: Date, beatsPerMinute: Double, timeZoneIdentifier: String? = nil, device: String) {
    self.id = id
    self.date = date
    self.beatsPerMinute = beatsPerMinute
    self.timeZoneIdentifier = timeZoneIdentifier
    self.device = device
  }
}

/// The source-prioritised step total of one bucket, as produced by a cumulative-sum statistics query.
public struct StepBucketTotal: Sendable, Hashable {
  public var bucket: StepBucket
  public var steps: Double

  public init(bucket: StepBucket, steps: Double) {
    self.bucket = bucket
    self.steps = steps
  }
}
