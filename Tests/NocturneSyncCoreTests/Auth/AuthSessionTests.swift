import Foundation
import Testing

@testable import NocturneSyncCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct AuthSessionSignInTests {
  @Test func usesCachedClientIDWithoutRegistering() async throws {
    let transport = FakeHTTPTransport()
    let store = InMemoryTokenStore(clientIDs: [AuthFixtures.baseURL: "cached-client"])
    let pending = try await AuthFixtures.session(transport, store: store).beginAuthorization()
    #expect(pending.clientID == "cached-client")
    #expect(await transport.requests.isEmpty)
    #expect(pending.url.absoluteString.contains("client_id=cached-client"))
    #expect(pending.url.absoluteString.contains("state=\(pending.state)"))
    #expect(pending.url.absoluteString.contains("code_challenge=\(pending.pkce.challenge)"))
  }

  @Test func registersOnceAndCachesTheClientID() async throws {
    let transport = FakeHTTPTransport(script: [.json(status: 200, AuthFixtures.registrationJSON)])
    let store = InMemoryTokenStore()
    let session = AuthFixtures.session(transport, store: store)
    let first = try await session.beginAuthorization()
    let second = try await session.beginAuthorization()
    #expect(first.clientID == "client-abc")
    #expect(second.clientID == "client-abc")
    #expect(await transport.requests.count == 1)
    #expect(store.events.contains(.saveClientID("client-abc", AuthFixtures.baseURL)))
    #expect(first.state != second.state)
    #expect(first.pkce != second.pkce)
  }

  @Test func failedRegistrationCachesNothing() async {
    let transport = FakeHTTPTransport(script: [.response(status: 429)])
    let store = InMemoryTokenStore()
    let error = await thrownAuthError { () throws(AuthError) in
      try await AuthFixtures.session(transport, store: store).beginAuthorization()
    }
    guard case .registrationFailed(.rateLimited) = error else {
      Issue.record("expected .registrationFailed(.rateLimited), got \(String(describing: error))")
      return
    }
    #expect(!store.events.contains { if case .saveClientID = $0 { true } else { false } })
  }

  @Test func completeExchangesCodeAndPersistsTokens() async throws {
    let transport = FakeHTTPTransport(script: [
      .json(status: 200, AuthFixtures.tokenJSON(access: "access-1", refresh: "refresh-1"))
    ])
    let store = InMemoryTokenStore(clientIDs: [AuthFixtures.baseURL: "client-abc"])
    let session = AuthFixtures.session(transport, store: store)
    let pending = try await session.beginAuthorization()
    let callback = URL(string: "com.pljeske.NocturneSync://oauth/callback?code=the-code&state=\(pending.state)")!

    try await session.completeAuthorization(callbackURL: callback, pending: pending)

    #expect(await session.isSignedIn)
    #expect(store.tokens?.accessToken == "access-1")
    #expect(store.tokens?.refreshToken == "refresh-1")
    let request = try #require(await transport.requests.first)
    let fields = formFields(request)
    #expect(fields["code"] == "the-code")
    #expect(fields["code_verifier"] == pending.pkce.verifier)
    #expect(fields["client_id"] == "client-abc")
    #expect(try await session.validAccessToken() == "access-1")
  }

  @Test func completeRejectsForeignStateWithoutNetwork() async throws {
    let transport = FakeHTTPTransport()
    let store = InMemoryTokenStore(clientIDs: [AuthFixtures.baseURL: "client-abc"])
    let session = AuthFixtures.session(transport, store: store)
    let pending = try await session.beginAuthorization()
    let callback = URL(string: "com.pljeske.NocturneSync://oauth/callback?code=the-code&state=forged")!
    let error = await thrownAuthError { () throws(AuthError) in
      try await session.completeAuthorization(callbackURL: callback, pending: pending)
    }
    guard case .stateMismatch = error else {
      Issue.record("expected .stateMismatch, got \(String(describing: error))")
      return
    }
    #expect(await transport.requests.isEmpty)
    #expect(await !session.isSignedIn)
  }

  @Test func exchangeFailureLeavesSessionSignedOut() async throws {
    let transport = FakeHTTPTransport(script: [
      .json(status: 400, #"{"error":"invalid_grant","error_description":"PKCE code_verifier validation failed."}"#)
    ])
    let store = InMemoryTokenStore(clientIDs: [AuthFixtures.baseURL: "client-abc"])
    let session = AuthFixtures.session(transport, store: store)
    let pending = try await session.beginAuthorization()
    let callback = URL(string: "com.pljeske.NocturneSync://oauth/callback?code=the-code&state=\(pending.state)")!
    let error = await thrownAuthError { () throws(AuthError) in
      try await session.completeAuthorization(callbackURL: callback, pending: pending)
    }
    guard case .exchangeFailed(.invalidGrant) = error else {
      Issue.record("expected .exchangeFailed(.invalidGrant), got \(String(describing: error))")
      return
    }
    #expect(await !session.isSignedIn)
    #expect(store.tokens == nil)
  }

  @Test func signOutClearsLocallyThenRevokes() async throws {
    let transport = FakeHTTPTransport(script: [.response(status: 200)])
    let store = InMemoryTokenStore(tokens: AuthFixtures.tokens(), clientIDs: [AuthFixtures.baseURL: "client-abc"])
    let session = AuthFixtures.session(transport, store: store)
    #expect(await session.isSignedIn)

    try await session.signOut()

    #expect(await !session.isSignedIn)
    #expect(store.tokens == nil)
    let request = try #require(await transport.requests.first)
    #expect(formFields(request)["token"] == "refresh-1")
    let error = await thrownAuthError { () throws(AuthError) in try await session.validAccessToken() }
    guard case .signedOut = error else {
      Issue.record("expected .signedOut, got \(String(describing: error))")
      return
    }
  }

  @Test func signOutIsSignedOutEvenWhenRevokeFails() async {
    let transport = FakeHTTPTransport(script: [.failure(URLError(.notConnectedToInternet))])
    let store = InMemoryTokenStore(tokens: AuthFixtures.tokens(), clientIDs: [AuthFixtures.baseURL: "client-abc"])
    let session = AuthFixtures.session(transport, store: store)
    let error = await thrownAuthError { () throws(AuthError) in try await session.signOut() }
    guard case .revokeFailed(.transport) = error else {
      Issue.record("expected .revokeFailed(.transport), got \(String(describing: error))")
      return
    }
    #expect(await !session.isSignedIn)
    #expect(store.tokens == nil)
  }
}

@Suite struct AuthSessionRefreshTests {
  let store = InMemoryTokenStore(
    tokens: AuthFixtures.tokens(expiresIn: 30),  // inside the 60 s leeway: needs refresh
    clientIDs: [AuthFixtures.baseURL: "client-abc"])

  @Test func validTokenIsReturnedWithoutNetwork() async throws {
    let transport = FakeHTTPTransport()
    let store = InMemoryTokenStore(
      tokens: AuthFixtures.tokens(expiresIn: 3600), clientIDs: [AuthFixtures.baseURL: "client-abc"])
    let token = try await AuthFixtures.session(transport, store: store).validAccessToken()
    #expect(token == "access-1")
    #expect(await transport.requests.isEmpty)
  }

  @Test func signedOutWithoutTokens() async {
    let error = await thrownAuthError { () throws(AuthError) in
      try await AuthFixtures.session(FakeHTTPTransport(), store: InMemoryTokenStore()).validAccessToken()
    }
    guard case .signedOut = error else {
      Issue.record("expected .signedOut, got \(String(describing: error))")
      return
    }
  }

  @Test func expiringTokenIsRefreshedAndPersistedBeforeReturn() async throws {
    let transport = FakeHTTPTransport(script: [
      .json(status: 200, AuthFixtures.tokenJSON(access: "access-2", refresh: "refresh-2"))
    ])
    let session = AuthFixtures.session(transport, store: store)

    let token = try await session.validAccessToken()

    #expect(token == "access-2")
    #expect(store.tokens?.refreshToken == "refresh-2")
    #expect(store.tokens?.expiresAt == AuthFixtures.now.addingTimeInterval(3600))
    let request = try #require(await transport.requests.first)
    #expect(formFields(request)["refresh_token"] == "refresh-1")
    // A second call within the lifetime hits neither the network nor the store.
    _ = try await session.validAccessToken()
    #expect(await transport.requests.count == 1)
  }

  @Test func concurrentCallersShareOneRefresh() async throws {
    let transport = GatedTransport(
      reply: .json(status: 200, AuthFixtures.tokenJSON(access: "access-2", refresh: "refresh-2")))
    let session = AuthFixtures.session(transport, store: store)

    let tokens = try await withThrowingTaskGroup(of: String.self) { group in
      for _ in 0..<10 {
        group.addTask { try await session.validAccessToken() }
      }
      // Let every caller reach the refresh, then release the single held request.
      while await transport.heldCount < 1 { await Task.yield() }
      try await Task.sleep(for: .milliseconds(20))
      await transport.release()
      return try await group.reduce(into: [String]()) { $0.append($1) }
    }

    #expect(tokens == Array(repeating: "access-2", count: 10))
    #expect(await transport.requests.count == 1)
    #expect(store.events.filter { if case .saveTokens = $0 { true } else { false } }.count == 1)
  }

  @Test func invalidGrantSignsOutAndStopsRetrying() async {
    let transport = FakeHTTPTransport(script: [
      .json(status: 400, #"{"error":"invalid_grant","error_description":"Refresh token has expired."}"#)
    ])
    let session = AuthFixtures.session(transport, store: store)

    let first = await thrownAuthError { () throws(AuthError) in try await session.validAccessToken() }
    guard case .signedOut = first else {
      Issue.record("expected .signedOut, got \(String(describing: first))")
      return
    }
    #expect(store.tokens == nil)
    #expect(store.events.contains(.clearTokens))
    #expect(await !session.isSignedIn)

    let second = await thrownAuthError { () throws(AuthError) in try await session.validAccessToken() }
    guard case .signedOut = second else {
      Issue.record("expected .signedOut again, got \(String(describing: second))")
      return
    }
    #expect(await transport.requests.count == 1)
  }

  @Test func transientRefreshFailureKeepsTokensAndRetriesNextTime() async throws {
    let transport = FakeHTTPTransport(script: [
      .response(status: 503), .json(status: 200, AuthFixtures.tokenJSON(access: "access-2", refresh: "refresh-2")),
    ])
    let session = AuthFixtures.session(transport, store: store)

    let error = await thrownAuthError { () throws(AuthError) in try await session.validAccessToken() }
    guard case .refreshFailed(.server(status: 503, retryAfter: nil)) = error else {
      Issue.record("expected .refreshFailed(.server(503)), got \(String(describing: error))")
      return
    }
    #expect(error?.isTransient == true)
    #expect(store.tokens?.refreshToken == "refresh-1")
    #expect(await session.isSignedIn)

    #expect(try await session.validAccessToken() == "access-2")
    #expect(await transport.requests.count == 2)
  }

  @Test func storeFailureKeepsNewTokensInMemoryAndRetriesPersisting() async throws {
    let transport = FakeHTTPTransport(script: [
      .json(status: 200, AuthFixtures.tokenJSON(access: "access-2", refresh: "refresh-2"))
    ])
    let session = AuthFixtures.session(transport, store: store)
    store.failSaves = true

    let error = await thrownAuthError { () throws(AuthError) in try await session.validAccessToken() }
    guard case .storage = error else {
      Issue.record("expected .storage, got \(String(describing: error))")
      return
    }
    #expect(store.tokens?.refreshToken == "refresh-1")

    store.failSaves = false
    #expect(try await session.validAccessToken() == "access-2")
    #expect(store.tokens?.refreshToken == "refresh-2")
    #expect(await transport.requests.count == 1)
  }

  @Test func refreshAfterUnauthorizedSkipsNetworkWhenTokenAlreadyRotated() async throws {
    let transport = FakeHTTPTransport()
    let store = InMemoryTokenStore(
      tokens: AuthFixtures.tokens(access: "access-2"), clientIDs: [AuthFixtures.baseURL: "client-abc"])
    let session = AuthFixtures.session(transport, store: store)
    #expect(try await session.refreshAfterUnauthorized(rejectedAccessToken: "access-1") == "access-2")
    #expect(await transport.requests.isEmpty)
  }

  @Test func refreshAfterUnauthorizedRefreshesCurrentToken() async throws {
    let transport = FakeHTTPTransport(script: [
      .json(status: 200, AuthFixtures.tokenJSON(access: "access-2", refresh: "refresh-2"))
    ])
    let store = InMemoryTokenStore(
      tokens: AuthFixtures.tokens(expiresIn: 3600), clientIDs: [AuthFixtures.baseURL: "client-abc"])
    let session = AuthFixtures.session(transport, store: store)
    #expect(try await session.refreshAfterUnauthorized(rejectedAccessToken: "access-1") == "access-2")
    #expect(await transport.requests.count == 1)
  }
}
