import Foundation

/// What this app tells the Nocturne instance about itself. Fixed per build; the user configures only
/// the base URL.
public struct OAuthConfiguration: Sendable, Hashable {
  /// Scopes the upload endpoints require. Nothing broader is ever requested.
  public static let requiredScopes = ["heartrate.readwrite", "stepcount.readwrite", "sleep.readwrite"]

  /// Dynamic registration is idempotent per `(tenant, software_id)`; this is the bundle id.
  public var softwareID: String
  /// Marketing version, reported as `software_version`.
  public var softwareVersion: String
  /// Shown on the consent page.
  public var clientName: String
  /// `<bundle-id>://oauth/callback`. Nocturne requires a reverse-DNS custom scheme, https, or loopback.
  public var redirectURI: URL
  public var scopes: [String]

  public init(
    softwareID: String,
    softwareVersion: String,
    clientName: String = NocturneConstants.appName,
    redirectURI: URL,
    scopes: [String] = OAuthConfiguration.requiredScopes
  ) {
    self.softwareID = softwareID
    self.softwareVersion = softwareVersion
    self.clientName = clientName
    self.redirectURI = redirectURI
    self.scopes = scopes
  }

  public var scopeString: String { scopes.joined(separator: " ") }
}
