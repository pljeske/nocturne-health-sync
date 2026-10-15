import Foundation

/// Resolves the `utcOffset` field: the recording app's time zone when the sample carries one
/// (`HKMetadataKeyTimeZone`), else the device time zone, both evaluated at the sample's instant so
/// DST is applied correctly.
public enum UTCOffsetResolver {
  public static func offsetMinutes(timeZoneIdentifier: String?, fallback: TimeZone, at instant: Date) -> Int {
    let zone = timeZoneIdentifier.flatMap { TimeZone(identifier: $0) } ?? fallback
    return zone.secondsFromGMT(for: instant) / 60
  }
}
