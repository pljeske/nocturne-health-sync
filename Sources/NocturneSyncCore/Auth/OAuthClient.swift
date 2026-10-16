import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Why an OAuth request failed. `invalidGrant` is split out because it alone means the grant is gone
/// and the user has to sign in again; every other `oauth` code is a programming or configuration error.
public enum OAuthClientError: Error, Sendable {
  /// 400 with `error: invalid_grant`: expired/replayed refresh token, revoked grant, bad code.
  case invalidGrant(description: String?)
  /// Any other 400 OAuth error (`invalid_request`, `invalid_client_metadata`, `invalid_scope`, ...).
  case oauth(code: String, description: String?)
  /// 429. The register and token endpoints are rate-limited; never loop on this.
  case rateLimited(retryAfter: TimeInterval?)
  /// 503 with `error: setup_required`.
  case setupRequired(message: String?)
  /// 503 with `error: recovery_mode_active`.
  case recoveryModeActive(message: String?)
  /// Any other 5xx.
  case server(status: Int, retryAfter: TimeInterval?)
  /// A status the contract does not define.
  case unexpectedStatus(Int)
  /// 2xx whose body is not the documented JSON (or lacks a refresh token).
  case invalidResponse(any Error)
  /// No HTTP response at all.
  case transport(any Error)
  case cancelled

  /// Whether retrying later, unchanged, can succeed.
  public var isTransient: Bool {
    switch self {
    case .rateLimited, .server, .transport: true
    case .invalidGrant, .oauth, .setupRequired, .recoveryModeActive, .unexpectedStatus, .invalidResponse, .cancelled:
      false
    }
  }

  init(rejecting response: HTTPURLResponse, body: Data, now: Date) {
    let status = response.statusCode
    precondition(!(200..<300).contains(status), "2xx is success, not an error")
    let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap {
      RetryAfter.seconds(from: $0, now: now)
    }
    switch status {
    case 400:
      let error = OAuthErrorBody.decode(body)
      if error?.error == "invalid_grant" {
        self = .invalidGrant(description: error?.errorDescription)
      } else {
        self = .oauth(code: error?.error ?? "unknown", description: error?.errorDescription)
      }
    case 429: self = .rateLimited(retryAfter: retryAfter)
    case 503:
      let unavailable = ServiceUnavailableBody.decode(body)
      switch unavailable?.error {
      case "setup_required": self = .setupRequired(message: unavailable?.message)
      case "recovery_mode_active": self = .recoveryModeActive(message: unavailable?.message)
      default: self = .server(status: status, retryAfter: retryAfter)
      }
    case 500..<600: self = .server(status: status, retryAfter: retryAfter)
    default: self = .unexpectedStatus(status)
    }
  }
}

/// The four Nocturne OAuth endpoints this app uses, over an unauthenticated `HTTPTransport`. Public
/// client (`token_endpoint_auth_method: none`), PKCE `S256`. No state: `AuthSession` owns the tokens.
public struct OAuthClient: Sendable {
  public let baseURL: URL
  private let transport: any HTTPTransport
  private let now: @Sendable () -> Date

  public init(baseURL: URL, transport: any HTTPTransport, now: @escaping @Sendable () -> Date = Date.init) {
    self.baseURL = baseURL
    self.transport = transport
    self.now = now
  }

  /// `POST /api/oauth/register` (RFC 7591). Returns the `client_id`. Idempotent on the server per
  /// `(tenant, software_id)`, but rate-limited to 10 per hour per IP: callers cache the result and
  /// never retry in a loop.
  public func register(_ configuration: OAuthConfiguration) async throws(OAuthClientError) -> String {
    let body = ClientRegistrationRequest(
      clientName: configuration.clientName,
      redirectURIs: [configuration.redirectURI.absoluteString],
      scope: configuration.scopeString,
      softwareID: configuration.softwareID,
      softwareVersion: configuration.softwareVersion)
    let data: Data
    do {
      data = try JSONEncoder().encode(body)
    } catch {
      throw .invalidResponse(error)
    }
    var request = URLRequest(url: baseURL.appending(path: "api/oauth/register"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = data
    let response = try await send(request, decoding: ClientRegistrationResponse.self)
    guard !response.clientID.isEmpty else {
      throw .invalidResponse(OAuthResponseError.missingField("client_id"))
    }
    return response.clientID
  }

  /// `GET /api/oauth/authorize` URL to open in `ASWebAuthenticationSession`.
  public func authorizationURL(clientID: String, configuration: OAuthConfiguration, state: String, pkce: PKCE) -> URL {
    var components = URLComponents(url: baseURL.appending(path: "api/oauth/authorize"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
      URLQueryItem(name: "scope", value: configuration.scopeString),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: pkce.challenge),
      URLQueryItem(name: "code_challenge_method", value: PKCE.method),
    ]
    return components.url!
  }

  /// `POST /api/oauth/token` with `grant_type=authorization_code`.
  public func exchange(code: String, pkce: PKCE, clientID: String, configuration: OAuthConfiguration)
    async throws(OAuthClientError)
    -> TokenSet
  {
    try await token(form: [
      ("grant_type", "authorization_code"),
      ("code", code),
      ("code_verifier", pkce.verifier),
      ("redirect_uri", configuration.redirectURI.absoluteString),
      ("client_id", clientID),
    ])
  }

  /// `POST /api/oauth/token` with `grant_type=refresh_token`. The returned set carries a new refresh
  /// token; the one passed in is dead once this returns 200, and replaying it revokes the grant.
  public func refresh(refreshToken: String, clientID: String) async throws(OAuthClientError) -> TokenSet {
    try await token(form: [
      ("grant_type", "refresh_token"),
      ("refresh_token", refreshToken),
      ("client_id", clientID),
    ])
  }

  /// `POST /api/oauth/revoke` (RFC 7009). Revoking the refresh token revokes the grant. 200 regardless
  /// of whether the token was known.
  public func revoke(refreshToken: String) async throws(OAuthClientError) {
    let request = formRequest(
      path: "api/oauth/revoke", form: [("token", refreshToken), ("token_type_hint", "refresh_token")])
    _ = try await send(request)
  }

  private func token(form: [(String, String)]) async throws(OAuthClientError) -> TokenSet {
    let issuedAt = now()
    let response = try await send(formRequest(path: "api/oauth/token", form: form), decoding: TokenResponse.self)
    guard !response.accessToken.isEmpty else { throw .invalidResponse(OAuthResponseError.missingField("access_token")) }
    guard let refreshToken = response.refreshToken, !refreshToken.isEmpty else {
      throw .invalidResponse(OAuthResponseError.missingField("refresh_token"))
    }
    return TokenSet(
      accessToken: response.accessToken,
      refreshToken: refreshToken,
      expiresAt: issuedAt.addingTimeInterval(TimeInterval(response.expiresIn)),
      scope: response.scope)
  }

  private func formRequest(path: String, form: [(String, String)]) -> URLRequest {
    var request = URLRequest(url: baseURL.appending(path: path))
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = Data(FormBody.encode(form).utf8)
    return request
  }

  private func send<Response: Decodable>(_ request: URLRequest, decoding: Response.Type) async throws(OAuthClientError)
    -> Response
  {
    let data = try await send(request)
    do {
      return try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw .invalidResponse(error)
    }
  }

  private func send(_ request: URLRequest) async throws(OAuthClientError) -> Data {
    let body: Data
    let response: HTTPURLResponse
    do {
      (body, response) = try await transport.send(request)
    } catch is CancellationError {
      throw .cancelled
    } catch let error as URLError where error.code == .cancelled {
      throw .cancelled
    } catch {
      throw .transport(error)
    }
    guard (200..<300).contains(response.statusCode) else {
      throw OAuthClientError(rejecting: response, body: body, now: now())
    }
    return body
  }
}

enum OAuthResponseError: Error, Equatable {
  case missingField(String)
}

/// `application/x-www-form-urlencoded` per the WHATWG URL standard: unreserved characters verbatim,
/// space as `+`, everything else percent-encoded as UTF-8.
enum FormBody {
  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._*")

  static func encode(_ fields: [(String, String)]) -> String {
    fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
  }

  private static func encode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved)!.replacingOccurrences(of: "%20", with: "+")
  }
}

struct ClientRegistrationRequest: Encodable {
  var clientName: String
  var redirectURIs: [String]
  var scope: String
  var softwareID: String
  var softwareVersion: String

  enum CodingKeys: String, CodingKey {
    case clientName = "client_name"
    case redirectURIs = "redirect_uris"
    case scope
    case softwareID = "software_id"
    case softwareVersion = "software_version"
  }
}

struct ClientRegistrationResponse: Decodable {
  var clientID: String

  enum CodingKeys: String, CodingKey {
    case clientID = "client_id"
  }
}

struct TokenResponse: Decodable {
  var accessToken: String
  var tokenType: String?
  var expiresIn: Int
  var refreshToken: String?
  var scope: String?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case tokenType = "token_type"
    case expiresIn = "expires_in"
    case refreshToken = "refresh_token"
    case scope
  }
}

/// `{ "error": "...", "error_description": "..." }`, RFC 6749 §5.2.
struct OAuthErrorBody: Decodable {
  var error: String
  var errorDescription: String?

  enum CodingKeys: String, CodingKey {
    case error
    case errorDescription = "error_description"
  }

  static func decode(_ data: Data) -> OAuthErrorBody? {
    guard !data.isEmpty else { return nil }
    return try? JSONDecoder().decode(OAuthErrorBody.self, from: data)
  }
}
