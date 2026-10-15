import Foundation

public enum HeartRateMapper {
  /// One sample becomes one record. `bpm` is rounded half away from zero.
  public static func record(from sample: HeartRateSample, deviceTimeZone: TimeZone) throws(MappingError)
    -> HeartRateRecord
  {
    HeartRateRecord(
      timestamp: sample.date,
      utcOffsetMinutes: UTCOffsetResolver.offsetMinutes(
        timeZoneIdentifier: sample.timeZoneIdentifier, fallback: deviceTimeZone, at: sample.date),
      bpm: try roundedBPM(sample.beatsPerMinute),
      device: sample.device,
      syncIdentifier: sample.id.uuidString
    )
  }

  static func roundedBPM(_ value: Double) throws(MappingError) -> Int {
    guard value >= 0, let bpm = Int(exactly: value.rounded(.toNearestOrAwayFromZero)) else {
      throw .invalidHeartRate(value)
    }
    return bpm
  }
}

public enum StepCountMapper {
  /// One bucket total becomes one record stamped with the bucket start. Zero totals map fine; the
  /// pipeline decides whether to upload them.
  public static func record(from total: StepBucketTotal, deviceTimeZone: TimeZone, device: String)
    throws(MappingError) -> StepCountRecord
  {
    let start = total.bucket.start
    return StepCountRecord(
      timestamp: start,
      utcOffsetMinutes: UTCOffsetResolver.offsetMinutes(timeZoneIdentifier: nil, fallback: deviceTimeZone, at: start),
      metric: try roundedSteps(total.steps),
      device: device,
      syncIdentifier: total.bucket.syncIdentifier
    )
  }

  static func roundedSteps(_ value: Double) throws(MappingError) -> Int {
    guard value >= 0, let steps = Int(exactly: value.rounded(.toNearestOrAwayFromZero)) else {
      throw .invalidStepCount(value)
    }
    return steps
  }
}
