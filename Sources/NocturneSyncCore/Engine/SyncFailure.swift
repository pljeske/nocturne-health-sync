import Foundation

/// Why one data type's sync did not complete. Stored as `SyncState.Failure.message` for the status
/// screen; the message never contains health values or tokens.
public enum SyncFailure: Error, Sendable {
  case upload(NocturneClientError)
  case health(HealthSourceError)
  case storage(any Error)

  /// Whether the remaining data types should be skipped too: the cause is not specific to one type
  /// (no grant, instance unusable, no network, out of time, local storage broken).
  public var stopsRun: Bool {
    switch self {
    case .upload(let error):
      switch error {
      case .auth(.signedOut), .unauthorized, .setupRequired, .recoveryModeActive, .transport, .rateLimited, .cancelled:
        true
      case .auth, .badRequest, .forbidden, .server, .unexpectedStatus, .encoding: false
      }
    case .health(.databaseInaccessible), .health(.healthDataUnavailable): true
    case .health: false
    case .storage: true
    }
  }

  public var message: String {
    switch self {
    case .upload(let error): Self.message(for: error)
    case .health(let error): Self.message(for: error)
    case .storage(let error): "Could not save sync progress on this device (\(error))."
    }
  }

  private static func message(for error: NocturneClientError) -> String {
    switch error {
    case .badRequest(let problem):
      problem?.message ?? "Nocturne rejected the upload as invalid."
    case .unauthorized:
      "Nocturne did not accept the sign-in. Sign in again."
    case .forbidden(let problem):
      "Nocturne denied access; the sign-in may lack the heart rate or step count scope."
        + (problem?.message.map { " (\($0))" } ?? "")
    case .setupRequired(let message):
      message ?? "The Nocturne instance has not finished its initial setup."
    case .recoveryModeActive(let message):
      message ?? "The Nocturne instance is in recovery mode."
    case .rateLimited:
      "Nocturne is limiting requests. Syncing will resume later."
    case .server(let status, _):
      "Nocturne returned HTTP \(status). Syncing will resume later."
    case .unexpectedStatus(let status, let problem):
      problem?.message ?? "Nocturne returned an unexpected HTTP \(status)."
    case .transport(let underlying):
      "Could not reach Nocturne (\(underlying.localizedDescription))."
    case .encoding:
      "Could not encode the records. This is a bug in NocturneSync."
    case .cancelled:
      "The upload was interrupted."
    case .auth(let authError):
      switch authError {
      case .signedOut: "Signed out. Sign in again to resume syncing."
      default: "Could not refresh the sign-in. Syncing will resume later."
      }
    }
  }

  private static func message(for error: HealthSourceError) -> String {
    switch error {
    case .databaseInaccessible: "Health data is locked until the device is unlocked."
    case .healthDataUnavailable: "Health data is not available on this device."
    case .authorizationNotDetermined: "Access to Health has not been requested yet."
    case .invalidAnchor: "The saved Health position was unreadable."
    case .misalignedStatistics:
      "Health returned step totals that are not on 5-minute boundaries. Steps were not uploaded."
    case .other(let underlying): "Reading Health failed (\(underlying.localizedDescription))."
    }
  }
}
