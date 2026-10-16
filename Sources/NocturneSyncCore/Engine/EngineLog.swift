#if canImport(os)
  import os
#endif

/// `os.Logger` for the engine on Apple platforms; compiled out elsewhere (Linux test runs). Free text
/// that may echo record contents (server problem details, mapping errors) is always `.private`.
enum EngineLog {
  #if canImport(os)
    private static let logger = Logger(subsystem: "com.pljeske.NocturneSync.Engine", category: "SyncEngine")
  #endif

  static func failed(_ type: HealthDataType, _ failure: SyncFailure) {
    #if canImport(os)
      logger.error("\(type.rawValue, privacy: .public) sync failed: \(failure.message, privacy: .private)")
    #endif
  }

  static func skippedSample(_ type: HealthDataType, _ error: MappingError) {
    #if canImport(os)
      logger.error(
        "Skipped an unmappable \(type.rawValue, privacy: .public) sample: \(String(describing: error), privacy: .private)"
      )
    #endif
  }

  static func resetCorruptState(_ error: any Error) {
    #if canImport(os)
      logger.error("Sync state was unreadable and was reset: \(String(describing: error), privacy: .private)")
    #endif
  }

  static func statusNotSaved(_ type: HealthDataType, _ failure: SyncFailure) {
    #if canImport(os)
      logger.error(
        "Could not record \(type.rawValue, privacy: .public) status: \(failure.message, privacy: .private)")
    #endif
  }

  static func finished(_ type: HealthDataType, uploaded: Int) {
    #if canImport(os)
      logger.info("\(type.rawValue, privacy: .public) sync finished, \(uploaded, privacy: .public) records committed")
    #endif
  }
}
