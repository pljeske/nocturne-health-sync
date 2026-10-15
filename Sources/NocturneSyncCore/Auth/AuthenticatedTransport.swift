import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Adds `Authorization: Bearer` from an `AuthSession` and, on 401, refreshes once and retries once. A
/// second 401 is returned as is, so `HTTPNocturneClient` reports `unauthorized`. `AuthError`s thrown
/// here pass through `HTTPNocturneClient` as `NocturneClientError.auth`.
public struct AuthenticatedTransport: HTTPTransport {
  private let base: any HTTPTransport
  private let session: AuthSession

  public init(base: any HTTPTransport, session: AuthSession) {
    self.base = base
    self.session = session
  }

  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let token = try await session.validAccessToken()
    let first = try await base.send(authorized(request, token: token))
    guard first.1.statusCode == 401 else { return first }
    let fresh = try await session.refreshAfterUnauthorized(rejectedAccessToken: token)
    return try await base.send(authorized(request, token: fresh))
  }

  private func authorized(_ request: URLRequest, token: String) -> URLRequest {
    var request = request
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    return request
  }
}
