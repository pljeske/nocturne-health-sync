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

/// One `sleepAnalysis` category sample: a contiguous interval in one sleep state, as recorded by one
/// source. Produced by `HealthSource`; `SleepSessionBuilder` groups them into sessions.
public struct SleepSample: Sendable, Hashable {
  /// `HKObject.uuid`. Not part of any server identity; a session is named by its day, not its samples.
  public var id: UUID
  public var start: Date
  public var end: Date
  public var stage: SleepStage
  /// `HKMetadataKeyTimeZone`, when the recording app set it.
  public var timeZoneIdentifier: String?
  /// Name of the recording device or source.
  public var device: String
  /// `HKMetadataKeyWasUserEntered`: typed into Health rather than recorded by a device.
  public var wasUserEntered: Bool

  public init(
    id: UUID, start: Date, end: Date, stage: SleepStage, timeZoneIdentifier: String? = nil, device: String,
    wasUserEntered: Bool = false
  ) {
    self.id = id
    self.start = start
    self.end = end
    self.stage = stage
    self.timeZoneIdentifier = timeZoneIdentifier
    self.device = device
    self.wasUserEntered = wasUserEntered
  }
}

/// `HKCategoryValueSleepAnalysis`, decoupled from HealthKit so the core builds without it.
public enum SleepStage: Sendable, Hashable, CaseIterable {
  case inBed
  case asleepUnspecified
  case awake
  case asleepCore
  case asleepDeep
  case asleepREM
  /// A value this build does not know (a stage added by a later iOS). Kept rather than dropped so the
  /// session has no hole; uploaded as Nocturne's `Unknown` stage.
  case unknown
}
