import Foundation

/// Persistence for the OAuth state that must survive relaunch: the current `TokenSet` and the
/// `client_id` dynamic registration issued, both per instance base URL. Keying tokens by instance
/// means a session for one instance can never send another instance's bearer token. The live implementation is the Keychain
/// (app target, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`); `AuthSession` is the only writer.
///
/// `client_id` is cached per base URL because registration is idempotent per `(tenant, software_id)`
/// but rate-limited to 10 per hour per IP; losing the cache must never put registration in a loop.
public protocol TokenStore: Sendable {
  func loadTokens(for baseURL: URL) throws -> TokenSet?
  func saveTokens(_ tokens: TokenSet, for baseURL: URL) throws
  func clearTokens(for baseURL: URL) throws

  func loadClientID(for baseURL: URL) throws -> String?
  func saveClientID(_ clientID: String, for baseURL: URL) throws
}
