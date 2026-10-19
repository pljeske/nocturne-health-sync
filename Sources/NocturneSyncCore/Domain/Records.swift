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

/// One Nocturne sleep session, field for field as `POST /api/v4/sleep/sessions/bulk` expects it: the
/// samples of one night (or nap) as stage intervals, plus the totals the server stores alongside them.
/// Built only by `SleepSessionBuilder`, which also names it.
public struct SleepSessionRecord: Sendable, Hashable {
  /// Nocturne's `SleepSessionType` members this app uses.
  public enum Kind: String, Sendable, Hashable {
    case overnight = "Overnight"
    case nap = "Nap"
  }

  /// Nocturne's `SleepDetectionMethod` members this app uses.
  public enum Detection: String, Sendable, Hashable {
    case auto = "Auto"
    case manual = "Manual"
  }

  /// Nocturne's `SleepStageType` members Health stages map to.
  public enum Stage: String, Sendable, Hashable {
    case inBed = "InBed"
    case asleep = "Asleep"
    case awake = "Awake"
    case light = "Light"
    case deep = "Deep"
    case rem = "Rem"
    case unknown = "Unknown"

    public init(_ stage: SleepStage) {
      self =
        switch stage {
        case .inBed: .inBed
        case .asleepUnspecified: .asleep
        case .awake: .awake
        case .asleepCore: .light
        case .asleepDeep: .deep
        case .asleepREM: .rem
        case .unknown: .unknown
        }
    }

    /// Whether time in this stage counts as sleep.
    public var isAsleep: Bool {
      switch self {
      case .asleep, .light, .deep, .rem: true
      case .inBed, .awake, .unknown: false
      }
    }
  }

  public struct StageInterval: Sendable, Hashable {
    public var start: Date
    public var end: Date
    public var stage: Stage

    public init(start: Date, end: Date, stage: Stage) {
      self.start = start
      self.end = end
      self.stage = stage
    }

    public var milliseconds: Int { Int((end.timeIntervalSince(start) * 1000).rounded()) }
  }

  /// Server-side identity together with `source`: `sleep-<sleep day>-<n>` (see `SleepSessionBuilder`).
  public var originalID: String
  public var start: Date
  public var end: Date
  /// IANA identifier of the zone the session was recorded in.
  public var timeZoneIdentifier: String
  public var kind: Kind
  public var isMainSleep: Bool
  public var detection: Detection
  public var device: String
  public var app: String
  /// Ordered by start. Intervals from different sources may overlap (iPhone "in bed" under Watch
  /// stages); the server counts sleep per stage, and `inBed` is neither sleep nor awake.
  public var stages: [StageInterval]
  /// Vital-sign averages while asleep. Empty until the pipeline fills it from Health.
  public var biometrics: SleepBiometrics

  public var source: String { NocturneConstants.sleepSource }

  public init(
    originalID: String, start: Date, end: Date, timeZoneIdentifier: String, kind: Kind, isMainSleep: Bool,
    detection: Detection, device: String, app: String, stages: [StageInterval],
    biometrics: SleepBiometrics = SleepBiometrics()
  ) {
    self.originalID = originalID
    self.start = start
    self.end = end
    self.timeZoneIdentifier = timeZoneIdentifier
    self.kind = kind
    self.isMainSleep = isMainSleep
    self.detection = detection
    self.device = device
    self.app = app
    self.stages = stages
    self.biometrics = biometrics
  }

  public var durationMs: Int { Int((end.timeIntervalSince(start) * 1000).rounded()) }
  public var totalSleepMs: Int { stages.filter(\.stage.isAsleep).reduce(0) { $0 + $1.milliseconds } }
  public var totalAwakeMs: Int { milliseconds(in: .awake) }
  /// Nil when no stage of the session was differentiated (a source that only knows "asleep").
  public var deepSleepMs: Int? { hasDifferentiatedStages ? milliseconds(in: .deep) : nil }
  public var lightSleepMs: Int? { hasDifferentiatedStages ? milliseconds(in: .light) : nil }
  public var remSleepMs: Int? { hasDifferentiatedStages ? milliseconds(in: .rem) : nil }

  private var hasDifferentiatedStages: Bool {
    stages.contains { [.light, .deep, .rem].contains($0.stage) }
  }

  private func milliseconds(in stage: Stage) -> Int {
    stages.filter { $0.stage == stage }.reduce(0) { $0 + $1.milliseconds }
  }

  /// Digest of everything the server stores, stable across launches, so a run can tell whether a
  /// session changed since it was last sent without keeping the session itself.
  public var contentDigest: String {
    var text = "\(originalID)|\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)|\(timeZoneIdentifier)|"
    text += "\(kind.rawValue)|\(isMainSleep)|\(detection.rawValue)|\(device)|\(app)"
    for interval in stages {
      text +=
        "|\(interval.start.timeIntervalSince1970),\(interval.end.timeIntervalSince1970),\(interval.stage.rawValue)"
    }
    let summary = [
      biometrics.averageHeartRate, biometrics.minimumHeartRate, biometrics.averageHRV,
      biometrics.averageRespiratoryRate, biometrics.averageOxygenSaturation,
    ]
    text += "|biometrics:" + summary.map { $0.map { "\($0)" } ?? "-" }.joined(separator: ",")
    return FNV1a.hexDigest(of: text)
  }
}
