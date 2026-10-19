import Foundation

/// Sleep days run from local noon to the next local noon, so a night is never split by midnight. A
/// session belongs to the day its start falls in. Local time is unavoidable here (a "night" is a
/// local notion), so the device time zone is part of every computation and changing zones moves the
/// boundaries (known gap, see README).
public enum SleepDays {
  /// The most recent local noon at or before `instant`.
  public static func dayStart(containing instant: Date, in zone: TimeZone) -> Date {
    let calendar = calendar(zone)
    let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: instant)!
    return noon <= instant ? noon : calendar.date(byAdding: .day, value: -1, to: noon)!
  }

  /// The day start `days` calendar days after `dayStart` (negative for earlier). DST-correct: the
  /// result is noon on the wall clock, whatever the day's length.
  public static func dayStart(_ dayStart: Date, offsetBy days: Int, in zone: TimeZone) -> Date {
    calendar(zone).date(byAdding: .day, value: days, to: dayStart)!
  }

  /// `yyyy-MM-dd` of the day that starts at `dayStart`. Part of sleep session identities.
  public static func label(_ dayStart: Date, in zone: TimeZone) -> String {
    let parts = calendar(zone).dateComponents([.year, .month, .day], from: dayStart)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
  }

  private static func calendar(_ zone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar
  }
}

/// Turns sleep samples into Nocturne sessions (decisions 11 and 12):
///
/// - Samples of every source and stage are sorted by start; a sample that begins more than
///   `sessionGap` after the running session's latest end starts a new session. Session bounds are the
///   earliest start and latest end of its samples.
/// - A session is named `sleep-<day>-<n>`: `day` is the sleep day (local noon to noon) its start
///   falls in, `n` its zero-based position by start among that day's sessions. Only the whole set of a
///   day is stable, so callers always upload a day's sessions together. A late or edited sample then
///   changes a session's content, not its name, and the server upsert replaces it; only a day whose
///   session count shrinks leaves its last name orphaned on the server (known gap).
/// - The longest session of a day is the overnight (main) sleep; the others are naps.
public enum SleepSessionBuilder {
  /// A pause longer than this between samples ends the session.
  public static let sessionGap: TimeInterval = 3600

  static let identifierPrefix = "sleep"

  /// Sessions for every sample, ordered by start. `samples` must all end after they start.
  public static func sessions(
    from samples: [SleepSample], timeZone: TimeZone, device: String, app: String, gap: TimeInterval = sessionGap
  ) -> [SleepSessionRecord] {
    let grouped = group(samples.sorted { ($0.start, $0.end) < ($1.start, $1.end) }, gap: gap)
    var byDay: [Date: [[SleepSample]]] = [:]
    var days: [Date] = []
    for session in grouped {
      let day = SleepDays.dayStart(containing: session[0].start, in: timeZone)
      if byDay[day] == nil { days.append(day) }
      byDay[day, default: []].append(session)
    }

    return days.flatMap { day -> [SleepSessionRecord] in
      let sessions = byDay[day]!
      let bounds = sessions.map { ($0[0].start, $0.map(\.end).max()!) }
      let longest = bounds.indices.max {
        bounds[$0].1.timeIntervalSince(bounds[$0].0) < bounds[$1].1.timeIntervalSince(bounds[$1].0)
      }
      let label = SleepDays.label(day, in: timeZone)
      return sessions.indices.map { index in
        record(
          sessions[index], bounds: bounds[index], originalID: "\(identifierPrefix)-\(label)-\(index)",
          isMain: index == longest, timeZone: timeZone, device: device, app: app)
      }
    }
  }

  private static func group(_ sorted: [SleepSample], gap: TimeInterval) -> [[SleepSample]] {
    var sessions: [[SleepSample]] = []
    var current: [SleepSample] = []
    var currentEnd = Date.distantPast
    for sample in sorted {
      if !current.isEmpty, sample.start.timeIntervalSince(currentEnd) > gap {
        sessions.append(current)
        current = []
      }
      current.append(sample)
      currentEnd = max(currentEnd, sample.end)
    }
    if !current.isEmpty { sessions.append(current) }
    return sessions
  }

  private static func record(
    _ samples: [SleepSample], bounds: (Date, Date), originalID: String, isMain: Bool, timeZone: TimeZone,
    device: String, app: String
  ) -> SleepSessionRecord {
    SleepSessionRecord(
      originalID: originalID,
      start: bounds.0,
      end: bounds.1,
      timeZoneIdentifier: samples.lazy.compactMap(\.timeZoneIdentifier).first ?? timeZone.identifier,
      kind: isMain ? .overnight : .nap,
      isMainSleep: isMain,
      detection: samples.allSatisfy(\.wasUserEntered) ? .manual : .auto,
      device: device,
      app: app,
      stages: samples.map { SleepSessionRecord.StageInterval(start: $0.start, end: $0.end, stage: .init($0.stage)) })
  }
}
