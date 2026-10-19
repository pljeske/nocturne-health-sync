/// The Health data types this app syncs. Adding a type means adding a pipeline (and a case here); the
/// raw value is used in file names and must not change once released.
public enum HealthDataType: String, Sendable, Hashable, Codable, CaseIterable {
  case heartRate
  case stepCount
  case sleep
}
