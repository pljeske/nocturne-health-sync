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

/// `timestamp` as the server's `DateTimeOffset` parses it: ISO 8601 with millisecond fraction, written
/// in the record's own UTC offset (`2024-07-01T12:00:00.250+02:00`). The server keeps only the instant,
/// so the offset here is informational; `utcOffset` is the field that carries local time.
enum ISO8601Timestamp {
  static func string(_ date: Date, utcOffsetMinutes: Int) -> String {
    let zone = TimeZone(secondsFromGMT: utcOffsetMinutes * 60) ?? TimeZone(secondsFromGMT: 0)!
    let style = Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true, timeZone: zone)
    return date.formatted(style)
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
