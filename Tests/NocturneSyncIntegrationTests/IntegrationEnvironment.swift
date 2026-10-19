import Foundation
import NocturneSyncCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Configuration from the environment (see docs/integration.md):
/// - `NOCTURNE_INTEGRATION_URL`: tenant URL of a development Nocturne, e.g. `http://localhost:1610`
///   when it has a single tenant. Unset: every integration test is skipped.
/// - `NOCTURNE_INTEGRATION_TOKEN`: bearer token, e.g. `accessToken` from `seed-tenant`. Unset: one is
///   fetched from the dev-only login endpoint, which exists only in Development builds of Nocturne.
/// - `NOCTURNE_INTEGRATION_TENANT`: tenant slug for that login when the host does not identify it.
enum IntegrationEnvironment {
  static let environment = ProcessInfo.processInfo.environment

  static var baseURL: URL? {
    environment["NOCTURNE_INTEGRATION_URL"].flatMap { $0.isEmpty ? nil : URL(string: $0) }
  }

  static var isConfigured: Bool { baseURL != nil }

  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  static func requireBaseURL() throws -> URL {
    guard let baseURL else { throw Failure(description: "NOCTURNE_INTEGRATION_URL is not set") }
    return baseURL
  }

  static func token() async throws -> String {
    if let token = environment["NOCTURNE_INTEGRATION_TOKEN"], !token.isEmpty { return token }
    var components = URLComponents(
      url: try requireBaseURL().appending(path: "api/v4/dev-only/auth/login"), resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "format", value: "json")]
    if let tenant = environment["NOCTURNE_INTEGRATION_TENANT"], !tenant.isEmpty {
      components.queryItems?.append(URLQueryItem(name: "tenant", value: tenant))
    }
    let (data, response) = try await URLSessionTransport().send(URLRequest(url: components.url!))
    guard response.statusCode == 200 else {
      throw Failure(
        description: "dev-only login returned HTTP \(response.statusCode): \(String(decoding: data, as: UTF8.self))")
    }
    // DevLoginResponse(TenantId, Slug, SubjectId, Username, AccessToken, RefreshToken, ExpiresInSeconds).
    struct DevLogin: Decodable { let accessToken: String }
    return try JSONDecoder().decode(DevLogin.self, from: data).accessToken
  }

  /// `GET <path>?from=&to=&count=` with a bearer token, decoded as an array.
  static func fetch<Record: Decodable>(
    _ type: Record.Type, path: String, around date: Date, token: String
  ) async throws -> [Record] {
    try await get(
      [Record].self, path: path, around: date, extra: [URLQueryItem(name: "count", value: "100000")], token: token)
  }

  /// `GET api/v4/sleep/sessions?from=&to=&limit=` with a bearer token; the `data` page of the response.
  static func fetchSleepSessions(around date: Date, token: String) async throws -> [StoredSleepSession] {
    struct Page: Decodable { let data: [StoredSleepSession] }
    return try await get(
      Page.self, path: "api/v4/sleep/sessions", around: date, extra: [URLQueryItem(name: "limit", value: "1000")],
      token: token
    ).data
  }

  private static func get<Response: Decodable>(
    _ type: Response.Type, path: String, around date: Date, extra: [URLQueryItem], token: String
  ) async throws -> Response {
    var components = URLComponents(url: try requireBaseURL().appending(path: path), resolvingAgainstBaseURL: false)!
    // A day either side absorbs a server that binds `Z` timestamps to its local time zone.
    let style = Date.ISO8601FormatStyle()
    components.queryItems =
      [
        URLQueryItem(name: "from", value: date.addingTimeInterval(-86_400).formatted(style)),
        URLQueryItem(name: "to", value: date.addingTimeInterval(86_400).formatted(style)),
      ] + extra
    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await URLSessionTransport().send(request)
    guard response.statusCode == 200 else {
      throw Failure(description: "GET \(path) returned HTTP \(response.statusCode)")
    }
    return try JSONDecoder().decode(Response.self, from: data)
  }
}

/// The fields of Nocturne's `SleepSession` read model this suite checks. The list endpoint omits stages.
struct StoredSleepSession: Decodable {
  let originalId: String?
  let source: String
  let type: String
  let startMills: Int
  let endMills: Int
  let totalSleepMs: Int
  let sourceApp: String?
  let sourceDevice: String?
}

/// Adds a fixed bearer token; the app uses `AuthenticatedTransport` with OAuth instead.
struct BearerTransport: HTTPTransport {
  let token: String
  let base = URLSessionTransport()

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    var request = request
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    return try await base.send(request)
  }
}

/// The fields of Nocturne's `HeartRate` read model this suite checks.
struct StoredHeartRate: Decodable {
  let syncIdentifier: String?
  let bpm: Int
  let utcOffset: Int?
  let device: String?
  let enteredBy: String?
  let dataSource: String?

  enum CodingKeys: String, CodingKey {
    case syncIdentifier, bpm, utcOffset, device, enteredBy
    case dataSource = "data_source"
  }
}

/// The fields of Nocturne's `StepCount` read model this suite checks.
struct StoredStepCount: Decodable {
  let syncIdentifier: String?
  let metric: Int
  let source: Int
  let utcOffset: Int?
  let enteredBy: String?
  let dataSource: String?

  enum CodingKeys: String, CodingKey {
    case syncIdentifier, metric, source, utcOffset, enteredBy
    case dataSource = "data_source"
  }
}
