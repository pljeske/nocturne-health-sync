import Foundation

/// Parses the `Retry-After` response header into a delay in seconds from `now`. Accepts the two forms
/// of RFC 9110 §10.2.3: a non-negative integer of seconds, or an IMF-fixdate (`Wed, 21 Oct 2015
/// 07:28:00 GMT`). The obsolete RFC 850 and asctime date forms are not accepted. A date in the past
/// yields 0. Anything else yields nil, which callers treat as "no hint".
enum RetryAfter {
  static func seconds(from headerValue: String, now: Date) -> TimeInterval? {
    let value = headerValue.trimmingCharacters(in: .whitespaces)
    if let seconds = Int(value) {
      return seconds >= 0 ? TimeInterval(seconds) : nil
    }
    if let date = imfFixdate(value) {
      return max(0, date.timeIntervalSince(now))
    }
    return nil
  }

  private static func imfFixdate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: value)
  }
}
