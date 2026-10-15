import Foundation
import NocturneSyncCore
import Security

/// `TokenStore` on the iOS Keychain. Generic-password items under one service, protected with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so background syncs after a reboot can read
/// them once the device has been unlocked once, and so they never migrate to another device.
///
/// Not covered by the core test suite (Security is Apple-only); exercised by the app on device.
struct KeychainTokenStore: TokenStore {
  enum Failure: Error {
    case unexpectedStatus(OSStatus)
    case corruptItem
  }

  private let service: String
  private static let tokensAccount = "oauth-tokens"

  /// - Parameter service: a reverse-DNS name unique to this app, typically the bundle id.
  init(service: String) {
    self.service = service
  }

  func loadTokens() throws -> TokenSet? {
    guard let data = try read(account: Self.tokensAccount) else { return nil }
    do {
      return try JSONDecoder().decode(TokenSet.self, from: data)
    } catch {
      throw Failure.corruptItem
    }
  }

  func saveTokens(_ tokens: TokenSet) throws {
    try write(try JSONEncoder().encode(tokens), account: Self.tokensAccount)
  }

  func clearTokens() throws {
    try delete(account: Self.tokensAccount)
  }

  func loadClientID(for baseURL: URL) throws -> String? {
    guard let data = try read(account: Self.clientIDAccount(for: baseURL)) else { return nil }
    guard let clientID = String(data: data, encoding: .utf8) else { throw Failure.corruptItem }
    return clientID
  }

  func saveClientID(_ clientID: String, for baseURL: URL) throws {
    try write(Data(clientID.utf8), account: Self.clientIDAccount(for: baseURL))
  }

  private static func clientIDAccount(for baseURL: URL) -> String {
    "oauth-client-id:\(baseURL.absoluteString)"
  }

  // MARK: SecItem

  private func baseQuery(account: String) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
  }

  private func read(account: String) throws -> Data? {
    var query = baseQuery(account: account)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data else { throw Failure.corruptItem }
      return data
    case errSecItemNotFound:
      return nil
    default:
      throw Failure.unexpectedStatus(status)
    }
  }

  private func write(_ data: Data, account: String) throws {
    let query = baseQuery(account: account)
    let attributes: [CFString: Any] = [
      kSecValueData: data,
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    switch update {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      let add = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
      guard add == errSecSuccess else { throw Failure.unexpectedStatus(add) }
    default:
      throw Failure.unexpectedStatus(update)
    }
  }

  private func delete(account: String) throws {
    let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unexpectedStatus(status) }
  }
}
