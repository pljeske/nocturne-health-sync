import Foundation

/// Wire form of `HeartRateRecord`: `UpsertHeartRateRequest` on the server. Keys are the server's
/// camelCase property names, so no key strategy is involved.
struct HeartRateRequestBody: Encodable, Equatable {
  var timestamp: String
  var utcOffset: Int
  var bpm: Int
  var accuracy: Int
  var device: String
  var app: String
  var dataSource: String
  var syncIdentifier: String

  init(_ record: HeartRateRecord) {
    timestamp = ISO8601Timestamp.string(record.timestamp, utcOffsetMinutes: record.utcOffsetMinutes)
    utcOffset = record.utcOffsetMinutes
    bpm = record.bpm
    accuracy = record.accuracy
    device = record.device
    app = record.app
    dataSource = record.dataSource
    syncIdentifier = record.syncIdentifier
  }
}

/// Wire form of `StepCountRecord`: `UpsertStepCountRequest` on the server.
struct StepCountRequestBody: Encodable, Equatable {
  var timestamp: String
  var utcOffset: Int
  var metric: Int
  var source: Int
  var device: String
  var app: String
  var dataSource: String
  var syncIdentifier: String

  init(_ record: StepCountRecord) {
    timestamp = ISO8601Timestamp.string(record.timestamp, utcOffsetMinutes: record.utcOffsetMinutes)
    utcOffset = record.utcOffsetMinutes
    metric = record.metric
    source = record.source
    device = record.device
    app = record.app
    dataSource = record.dataSource
    syncIdentifier = record.syncIdentifier
  }
}

/// Wire form of `SleepSessionRecord`: Nocturne's `SleepSession` model, the fields this app fills. Times
/// are `DateTime` on the server and must be UTC with a `Z` suffix: an offset form would be converted
/// to the server's local time and then rejected by its UTC-only storage.
struct SleepSessionRequestBody: Encodable, Equatable {
  var startTime: String
  var endTime: String
  var timezone: String
  var type: String
  var detectionMethod: String
  var isMainSleep: Bool
  var durationMs: Int
  var totalSleepMs: Int
  var totalAwakeMs: Int
  var deepSleepMs: Int?
  var lightSleepMs: Int?
  var remSleepMs: Int?
  var source: String
  var sourceDevice: String
  var sourceApp: String
  var originalId: String
  var stages: [SleepStageRequestBody]

  init(_ record: SleepSessionRecord) {
    startTime = ISO8601Timestamp.utcString(record.start)
    endTime = ISO8601Timestamp.utcString(record.end)
    timezone = record.timeZoneIdentifier
    type = record.kind.rawValue
    detectionMethod = record.detection.rawValue
    isMainSleep = record.isMainSleep
    durationMs = record.durationMs
    totalSleepMs = record.totalSleepMs
    totalAwakeMs = record.totalAwakeMs
    deepSleepMs = record.deepSleepMs
    lightSleepMs = record.lightSleepMs
    remSleepMs = record.remSleepMs
    source = record.source
    sourceDevice = record.device
    sourceApp = record.app
    originalId = record.originalID
    stages = record.stages.enumerated().map { SleepStageRequestBody($1, ordinal: $0) }
  }
}

/// Nocturne's `SleepStageInterval`.
struct SleepStageRequestBody: Encodable, Equatable {
  var startTime: String
  var endTime: String
  var stage: String
  var ordinal: Int

  init(_ interval: SleepSessionRecord.StageInterval, ordinal: Int) {
    startTime = ISO8601Timestamp.utcString(interval.start)
    endTime = ISO8601Timestamp.utcString(interval.end)
    stage = interval.stage.rawValue
    self.ordinal = ordinal
  }
}

/// `timestamp` as the server's `DateTimeOffset` parses it: ISO 8601 with millisecond fraction, written
/// in the record's own UTC offset (`2024-07-01T12:00:00.250+02:00`). The server keeps only the instant,
/// so the offset here is informational; `utcOffset` is the field that carries local time.
enum ISO8601Timestamp {
  static func string(_ date: Date, utcOffsetMinutes: Int) -> String {
    let zone = TimeZone(secondsFromGMT: utcOffsetMinutes * 60) ?? TimeZone(secondsFromGMT: 0)!
    let style = Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true, timeZone: zone)
    return date.formatted(style)
  }

  /// UTC with a `Z` suffix and millisecond fraction (`2024-07-01T10:00:00.250Z`), for the server's
  /// `DateTime` fields.
  static func utcString(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
  }
}

enum RequestEncoder {
  /// Encodes one request body: a JSON array of records. Keys are sorted so the output is byte-stable,
  /// which the golden tests rely on; the server does not care.
  static func encode(_ bodies: [some Encodable]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(bodies)
  }
}
