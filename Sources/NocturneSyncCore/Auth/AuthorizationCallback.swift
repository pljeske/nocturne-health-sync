import Foundation

/// Everything the app needs to drive one browser sign-in: open `url`, then hand the callback URL and
/// this value back to `AuthSession.completeAuthorization`.
public struct PendingAuthorization: Sendable, Hashable {
  public let url: URL
  public let clientID: String
  public let state: String
  public let pkce: PKCE

  public init(url: URL, clientID: String, state: String, pkce: PKCE) {
    self.url = url
    self.clientID = clientID
    self.state = state
    self.pkce = pkce
  }
}

/// Parses the redirect `<bundle-id>://oauth/callback?code=...&state=...` (or `?error=...`).
enum AuthorizationCallback {
  static func code(from url: URL, expectedState: String) throws(AuthError) -> String {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw .malformedCallback
    }
    let query = Dictionary(
      (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    guard query["state"] == expectedState else { throw .stateMismatch }
    if let error = query["error"] {
      throw .authorizationDenied(code: error, description: query["error_description"])
    }
    guard let code = query["code"], !code.isEmpty else { throw .malformedCallback }
    return code
  }

  static func randomState() -> String {
    var generator = SystemRandomNumberGenerator()
    return Base64URL.encode((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
  }
}
