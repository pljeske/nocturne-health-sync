import Foundation
import Testing

@testable import NocturneSyncCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct AuthenticatedTransportTests {
  let apiURL = URL(string: "https://tenant.example.test/api/v4/HeartRate")!

  /// One fake answers both the token endpoint and the API; the script is consumed in call order.
  func makeStack(script: [FakeHTTPTransport.Reply], tokens: TokenSet = AuthFixtures.tokens(expiresIn: 3600))
    -> (FakeHTTPTransport, AuthenticatedTransport, AuthSession)
  {
    let transport = FakeHTTPTransport(script: script)
    let store = InMemoryTokenStore(tokens: tokens, clientIDs: [AuthFixtures.baseURL: "client-abc"])
    let session = AuthFixtures.session(transport, store: store)
    return (transport, AuthenticatedTransport(base: transport, session: session), session)
  }

  @Test func addsBearerHeader() async throws {
    let (transport, authenticated, _) = makeStack(script: [.response(status: 200)])
    let (_, response) = try await authenticated.send(URLRequest(url: apiURL))
    #expect(response.statusCode == 200)
    let requests = await transport.requests
    #expect(requests.count == 1)
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
  }

  @Test func unauthorizedRefreshesOnceAndRetriesOnce() async throws {
    let (transport, authenticated, _) = makeStack(script: [
      .response(status: 401),
      .json(status: 200, AuthFixtures.tokenJSON(access: "access-2", refresh: "refresh-2")),
      .response(status: 200),
    ])
    let (_, response) = try await authenticated.send(URLRequest(url: apiURL))
    #expect(response.statusCode == 200)
    let requests = await transport.requests
    #expect(requests.map { $0.url?.path } == ["/api/v4/HeartRate", "/api/oauth/token", "/api/v4/HeartRate"])
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
    #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer access-2")
    #expect(formFields(requests[1])["refresh_token"] == "refresh-1")
  }

  @Test func secondUnauthorizedIsReturnedToTheCaller() async throws {
    let (transport, authenticated, _) = makeStack(script: [
      .response(status: 401),
      .json(status: 200, AuthFixtures.tokenJSON(access: "access-2", refresh: "refresh-2")),
      .response(status: 401),
    ])
    let (_, response) = try await authenticated.send(URLRequest(url: apiURL))
    #expect(response.statusCode == 401)
    #expect(await transport.requests.count == 3)
  }

  @Test func clientMapsSecondUnauthorizedToUnauthorized() async {
    let (_, authenticated, _) = makeStack(script: [
      .response(status: 401),
      .json(status: 200, AuthFixtures.tokenJSON(access: "access-2", refresh: "refresh-2")),
      .response(status: 401),
    ])
    let client = HTTPNocturneClient(baseURL: AuthFixtures.baseURL, transport: authenticated)
    let error = await thrownError { () throws(NocturneClientError) in
      try await client.uploadHeartRates(Fixtures.heartRates(1))
    }
    guard case .unauthorized = error else {
      Issue.record("expected .unauthorized, got \(String(describing: error))")
      return
    }
  }

  @Test func revokedGrantSurfacesAsSignedOutThroughTheClient() async {
    let (transport, authenticated, session) = makeStack(script: [
      .response(status: 401),
      .json(status: 400, #"{"error":"invalid_grant","error_description":"Authorization grant has been revoked."}"#),
    ])
    let client = HTTPNocturneClient(baseURL: AuthFixtures.baseURL, transport: authenticated)
    let error = await thrownError { () throws(NocturneClientError) in
      try await client.uploadHeartRates(Fixtures.heartRates(1))
    }
    guard case .auth(.signedOut) = error else {
      Issue.record("expected .auth(.signedOut), got \(String(describing: error))")
      return
    }
    #expect(error?.isTransient == false)
    #expect(await !session.isSignedIn)
    #expect(await transport.requests.count == 2)
  }

  @Test func signedOutSessionNeverHitsTheAPI() async {
    let transport = FakeHTTPTransport()
    let session = AuthFixtures.session(transport, store: InMemoryTokenStore())
    let client = HTTPNocturneClient(
      baseURL: AuthFixtures.baseURL, transport: AuthenticatedTransport(base: transport, session: session))
    let error = await thrownError { () throws(NocturneClientError) in
      try await client.uploadStepCounts(Fixtures.stepCounts(1))
    }
    guard case .auth(.signedOut) = error else {
      Issue.record("expected .auth(.signedOut), got \(String(describing: error))")
      return
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test func transientRefreshFailureIsTransientThroughTheClient() async {
    let (_, authenticated, session) = makeStack(script: [.response(status: 401), .response(status: 503)])
    let client = HTTPNocturneClient(baseURL: AuthFixtures.baseURL, transport: authenticated)
    let error = await thrownError { () throws(NocturneClientError) in
      try await client.uploadHeartRates(Fixtures.heartRates(1))
    }
    guard case .auth(.refreshFailed(.server(status: 503, retryAfter: nil))) = error else {
      Issue.record("expected .auth(.refreshFailed(.server(503))), got \(String(describing: error))")
      return
    }
    #expect(error?.isTransient == true)
    #expect(await session.isSignedIn)
  }
}
