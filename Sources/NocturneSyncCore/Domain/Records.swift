import Foundation

/// One Nocturne `HeartRate` record, field for field as `POST /api/v4/HeartRate` expects it.
public struct HeartRateRecord: Sendable, Hashable {
  public var timestamp: Date
  /// Offset of the local time at `timestamp`, in minutes east of UTC.
  public var utcOffsetMinutes: Int
  public var bpm: Int
  /// HealthKit provides no accuracy; always 0.
  public var accuracy: Int
  public var device: String
  public var app: String
  public var syncIdentifier: String

  public var dataSource: String { NocturneConstants.dataSource }

  public init(
    timestamp: Date,
    utcOffsetMinutes: Int,
    bpm: Int,
    accuracy: Int = 0,
    device: String,
    app: String = NocturneConstants.appName,
    syncIdentifier: String
  ) {
    self.timestamp = timestamp
    self.utcOffsetMinutes = utcOffsetMinutes
    self.bpm = bpm
    self.accuracy = accuracy
    self.device = device
    self.app = app
    self.syncIdentifier = syncIdentifier
  }
}

/// One Nocturne `StepCount` record: the step total of one bucket.
public struct StepCountRecord: Sendable, Hashable {
  /// Bucket start.
  public var timestamp: Date
  public var utcOffsetMinutes: Int
  public var metric: Int
  /// Nocturne source bitmask. Bit 0 clear: per-interval delta. Bit 1 clear: safe to sum.
  /// Always 0; never set bit 1.
  public var source: Int
  public var device: String
  public var app: String
  public var syncIdentifier: String

  public var dataSource: String { NocturneConstants.dataSource }

  public init(
    timestamp: Date,
    utcOffsetMinutes: Int,
    metric: Int,
    source: Int = 0,
    device: String,
    app: String = NocturneConstants.appName,
    syncIdentifier: String
  ) {
    self.timestamp = timestamp
    self.utcOffsetMinutes = utcOffsetMinutes
    self.metric = metric
    self.source = source
    self.device = device
    self.app = app
    self.syncIdentifier = syncIdentifier
  }
}
