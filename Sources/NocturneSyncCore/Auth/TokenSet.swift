import Foundation

/// The outcome of a token exchange or refresh. One `TokenSet` is current at any time; the refresh
/// token in it is single-use (Nocturne rotates on every refresh and revokes the grant on replay).
public struct TokenSet: Sendable, Hashable, Codable {
  public var accessToken: String
  public var refreshToken: String
  /// Instant the access token stops being accepted.
  public var expiresAt: Date
  /// Space-separated scopes the server granted, when it said.
  public var scope: String?

  public init(accessToken: String, refreshToken: String, expiresAt: Date, scope: String? = nil) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
    self.scope = scope
  }

  /// Whether the access token is still usable at `instant`, with `leeway` seconds of margin for clock
  /// skew and request latency.
  public func isAccessTokenValid(at instant: Date, leeway: TimeInterval) -> Bool {
    expiresAt.timeIntervalSince(instant) > leeway
  }
}
