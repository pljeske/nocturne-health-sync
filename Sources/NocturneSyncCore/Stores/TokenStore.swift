import Foundation

/// Persistence for the OAuth state that must survive relaunch: the current `TokenSet` and the
/// `client_id` dynamic registration issued per instance. The live implementation is the Keychain
/// (app target, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`); `AuthSession` is the only writer.
///
/// `client_id` is cached per base URL because registration is idempotent per `(tenant, software_id)`
/// but rate-limited to 10 per hour per IP; losing the cache must never put registration in a loop.
public protocol TokenStore: Sendable {
  func loadTokens() throws -> TokenSet?
  func saveTokens(_ tokens: TokenSet) throws
  func clearTokens() throws

  func loadClientID(for baseURL: URL) throws -> String?
  func saveClientID(_ clientID: String, for baseURL: URL) throws
}
