import Foundation
import NocturneSyncCore

/// Something to tell the user after an action (sign-in, sign-out, Health access). Sync failures are
/// shown per type on the status screen instead, from `SyncState.Failure`.
public struct UserMessage: Sendable, Equatable, Identifiable {
  public var id: String { text }
  public let text: String

  public init(_ text: String) {
    self.text = text
  }

  init(_ error: AuthError) {
    switch error {
    case .signedOut:
      self.init("Signed out. Sign in again to resume syncing.")
    case .registrationFailed(.rateLimited):
      self.init("Nocturne is limiting app registrations. Try again in an hour.")
    case .registrationFailed(let error), .exchangeFailed(let error):
      self.init(Self.text(for: error))
    case .authorizationDenied(let code, let description):
      self.init(
        code == "access_denied"
          ? "Access was declined in Nocturne." : "Nocturne refused the sign-in (\(description ?? code)).")
    case .stateMismatch:
      self.init("The sign-in response did not belong to this attempt. Try again.")
    case .malformedCallback:
      self.init("Nocturne returned an incomplete sign-in response. Try again.")
    case .refreshFailed(let error):
      self.init(Self.text(for: error))
    case .revokeFailed:
      self.init("Signed out on this device, but Nocturne could not be told to revoke the access.")
    case .storage:
      self.init("Could not store the sign-in on this device.")
    }
  }

  init(_ error: HealthSourceError) {
    switch error {
    case .healthDataUnavailable: self.init("Health data is not available on this device.")
    case .databaseInaccessible: self.init("Unlock the device to let NocturneSync read Health data.")
    default: self.init("Could not set up Health access (\(error)).")
    }
  }

  static func text(for error: OAuthClientError) -> String {
    switch error {
    case .invalidGrant: "Nocturne rejected the sign-in. Try again."
    case .oauth(let code, let description): description ?? "Nocturne rejected the request (\(code))."
    case .rateLimited: "Nocturne is limiting sign-in attempts. Try again later."
    case .setupRequired(let message): message ?? "The Nocturne instance has not finished its initial setup."
    case .recoveryModeActive(let message): message ?? "The Nocturne instance is in recovery mode."
    case .server(let status, _): "Nocturne returned HTTP \(status). Try again later."
    case .unexpectedStatus(let status): "Nocturne returned HTTP \(status). Is this the address of a Nocturne instance?"
    case .invalidResponse: "The response was not understood. Is this the address of a Nocturne instance?"
    case .transport(let underlying): "Could not reach the instance (\(underlying.localizedDescription))."
    case .cancelled: "The sign-in was interrupted."
    }
  }
}
