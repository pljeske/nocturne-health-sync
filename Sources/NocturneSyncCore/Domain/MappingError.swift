/// A Health value that cannot be represented as a Nocturne record. Such a sample is a bug in the
/// producer, not a transient condition, so it is never retried.
public enum MappingError: Error, Equatable, Sendable {
  /// NaN, infinite, negative, or beyond `Int`.
  case invalidHeartRate(Double)
  /// NaN, infinite, negative, or beyond `Int`.
  case invalidStepCount(Double)
}
