import Foundation

@testable import NocturneSyncCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum AuthFixtures {
  static let baseURL = URL(string: "https://tenant.example.test")!
  static let now = Date(timeIntervalSince1970: 1_720_000_000)
  static let configuration = OAuthConfiguration(
    softwareID: "com.pljeske.NocturneSync",
    softwareVersion: "0.1.0",
    redirectURI: URL(string: "com.pljeske.NocturneSync://oauth/callback")!)

  static func tokens(access: String = "access-1", refresh: String = "refresh-1", expiresIn: TimeInterval = 3600)
    -> TokenSet
  {
    TokenSet(
      accessToken: access, refreshToken: refresh, expiresAt: now.addingTimeInterval(expiresIn),
      scope: "heartrate.readwrite")
  }

  static func tokenJSON(access: String, refresh: String? = "refresh-2", expiresIn: Int = 3600) -> String {
    let refreshField = refresh.map { ",\"refresh_token\":\"\($0)\"" } ?? ""
    return """
      {"access_token":"\(access)","token_type":"Bearer","expires_in":\(expiresIn)\(refreshField),\
      "scope":"heartrate.readwrite stepcount.readwrite sleep.readwrite"}
      """
  }

  static let registrationJSON = """
    {"client_id":"client-abc","client_id_issued_at":1720000000,"client_name":"NocturneSync",\
    "redirect_uris":["com.pljeske.NocturneSync://oauth/callback"],"grant_types":["authorization_code","refresh_token"],\
    "response_types":["code"],"token_endpoint_auth_method":"none","scope":"heartrate.readwrite stepcount.readwrite sleep.readwrite",\
    "software_id":"com.pljeske.NocturneSync"}
    """

  static func client(_ transport: any HTTPTransport) -> OAuthClient {
    OAuthClient(baseURL: baseURL, transport: transport, now: { now })
  }

  static func session(
    _ transport: any HTTPTransport, store: InMemoryTokenStore, now: @escaping @Sendable () -> Date = { now }
  )
    -> AuthSession
  {
    AuthSession(
      client: OAuthClient(baseURL: baseURL, transport: transport, now: now), configuration: configuration, store: store,
      now: now)
  }
}

/// Runs `body` and returns the `AuthError` it threw, or nil if it succeeded.
func thrownAuthError<T>(_ body: () async throws(AuthError) -> T) async -> AuthError? {
  do {
    _ = try await body()
    return nil
  } catch {
    return error
  }
}

/// Runs `body` and returns the `OAuthClientError` it threw, or nil if it succeeded.
func thrownOAuthError<T>(_ body: () async throws(OAuthClientError) -> T) async -> OAuthClientError? {
  do {
    _ = try await body()
    return nil
  } catch {
    return error
  }
}

/// Decodes a form-urlencoded body into a dictionary.
func formFields(_ request: URLRequest) -> [String: String] {
  let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
  var components = URLComponents()
  components.percentEncodedQuery = body.replacingOccurrences(of: "+", with: "%20")
  return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
}
