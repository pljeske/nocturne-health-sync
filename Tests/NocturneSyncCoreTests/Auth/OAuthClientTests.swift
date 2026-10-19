import Foundation
import Testing

@testable import NocturneSyncCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct OAuthClientTests {
  @Test func registrationSendsRFC7591Metadata() async throws {
    let transport = FakeHTTPTransport(script: [.json(status: 200, AuthFixtures.registrationJSON)])
    let clientID = try await AuthFixtures.client(transport).register(AuthFixtures.configuration)
    #expect(clientID == "client-abc")

    let request = try #require(await transport.requests.first)
    #expect(request.url?.absoluteString == "https://tenant.example.test/api/oauth/register")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
    #expect(body["client_name"] as? String == "NocturneSync")
    #expect(body["redirect_uris"] as? [String] == ["com.pljeske.NocturneSync://oauth/callback"])
    #expect(body["scope"] as? String == "heartrate.readwrite stepcount.readwrite sleep.readwrite")
    #expect(body["software_id"] as? String == "com.pljeske.NocturneSync")
    #expect(body["software_version"] as? String == "0.1.0")
    #expect(body.count == 5)
  }

  @Test func registrationErrorIsSurfacedWithCode() async {
    let transport = FakeHTTPTransport(script: [
      .json(
        status: 400,
        #"{"error":"invalid_redirect_uri","error_description":"The following redirect_uris are not allowed: x."}"#)
    ])
    let error = await thrownOAuthError { () throws(OAuthClientError) in
      try await AuthFixtures.client(transport).register(AuthFixtures.configuration)
    }
    guard case .oauth(code: "invalid_redirect_uri", description: let description) = error else {
      Issue.record("expected .oauth, got \(String(describing: error))")
      return
    }
    #expect(description == "The following redirect_uris are not allowed: x.")
    #expect(error?.isTransient == false)
  }

  @Test func registrationRateLimitIsNotTransientlyHidden() async {
    let transport = FakeHTTPTransport(script: [.response(status: 429, headers: ["Retry-After": "600"])])
    let error = await thrownOAuthError { () throws(OAuthClientError) in
      try await AuthFixtures.client(transport).register(AuthFixtures.configuration)
    }
    guard case .rateLimited(retryAfter: 600) = error else {
      Issue.record("expected .rateLimited(600), got \(String(describing: error))")
      return
    }
  }

  @Test func authorizationURLCarriesPKCEAndState() throws {
    let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    let url = AuthFixtures.client(FakeHTTPTransport()).authorizationURL(
      clientID: "client-abc", configuration: AuthFixtures.configuration, state: "st4te", pkce: pkce)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.scheme == "https")
    #expect(components.host == "tenant.example.test")
    #expect(components.path == "/api/oauth/authorize")
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(
      query == [
        "response_type": "code",
        "client_id": "client-abc",
        "redirect_uri": "com.pljeske.NocturneSync://oauth/callback",
        "scope": "heartrate.readwrite stepcount.readwrite sleep.readwrite",
        "state": "st4te",
        "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        "code_challenge_method": "S256",
      ])
  }

  @Test func exchangePostsFormEncodedCodeGrant() async throws {
    let transport = FakeHTTPTransport(script: [
      .json(status: 200, AuthFixtures.tokenJSON(access: "access-1", refresh: "refresh-1"))
    ])
    let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    let tokens = try await AuthFixtures.client(transport).exchange(
      code: "c0de+/=", pkce: pkce, clientID: "client-abc", configuration: AuthFixtures.configuration)

    let request = try #require(await transport.requests.first)
    #expect(request.url?.absoluteString == "https://tenant.example.test/api/oauth/token")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    #expect(
      formFields(request) == [
        "grant_type": "authorization_code",
        "code": "c0de+/=",
        "code_verifier": pkce.verifier,
        "redirect_uri": "com.pljeske.NocturneSync://oauth/callback",
        "client_id": "client-abc",
      ])
    #expect(String(decoding: request.httpBody!, as: UTF8.self).contains("code=c0de%2B%2F%3D"))

    #expect(tokens.accessToken == "access-1")
    #expect(tokens.refreshToken == "refresh-1")
    #expect(tokens.expiresAt == AuthFixtures.now.addingTimeInterval(3600))
    #expect(tokens.scope == "heartrate.readwrite stepcount.readwrite sleep.readwrite")
  }

  @Test func refreshPostsFormEncodedRefreshGrant() async throws {
    let transport = FakeHTTPTransport(script: [
      .json(status: 200, AuthFixtures.tokenJSON(access: "access-2", refresh: "refresh-2"))
    ])
    let tokens = try await AuthFixtures.client(transport).refresh(refreshToken: "refresh-1", clientID: "client-abc")
    let request = try #require(await transport.requests.first)
    #expect(
      formFields(request) == ["grant_type": "refresh_token", "refresh_token": "refresh-1", "client_id": "client-abc"])
    #expect(tokens.refreshToken == "refresh-2")
  }

  @Test func invalidGrantIsItsOwnCase() async {
    let transport = FakeHTTPTransport(script: [
      .json(status: 400, #"{"error":"invalid_grant","error_description":"Refresh token has been revoked."}"#)
    ])
    let error = await thrownOAuthError { () throws(OAuthClientError) in
      try await AuthFixtures.client(transport).refresh(refreshToken: "old", clientID: "client-abc")
    }
    guard case .invalidGrant(description: "Refresh token has been revoked.") = error else {
      Issue.record("expected .invalidGrant, got \(String(describing: error))")
      return
    }
    #expect(error?.isTransient == false)
  }

  @Test func tokenResponseWithoutRefreshTokenIsInvalid() async {
    let transport = FakeHTTPTransport(script: [.json(status: 200, AuthFixtures.tokenJSON(access: "a", refresh: nil))])
    let error = await thrownOAuthError { () throws(OAuthClientError) in
      try await AuthFixtures.client(transport).refresh(refreshToken: "old", clientID: "client-abc")
    }
    guard case .invalidResponse(let underlying) = error else {
      Issue.record("expected .invalidResponse, got \(String(describing: error))")
      return
    }
    #expect(underlying as? OAuthResponseError == .missingField("refresh_token"))
  }

  @Test func malformedJSONIsInvalidResponse() async {
    let transport = FakeHTTPTransport(script: [.response(status: 200, body: Data("<html>".utf8))])
    let error = await thrownOAuthError { () throws(OAuthClientError) in
      try await AuthFixtures.client(transport).refresh(refreshToken: "old", clientID: "client-abc")
    }
    guard case .invalidResponse = error else {
      Issue.record("expected .invalidResponse, got \(String(describing: error))")
      return
    }
  }

  @Test(arguments: [500, 502, 503])
  func serverErrorsAreTransient(status: Int) async {
    let transport = FakeHTTPTransport(script: [.response(status: status)])
    let error = await thrownOAuthError { () throws(OAuthClientError) in
      try await AuthFixtures.client(transport).refresh(refreshToken: "old", clientID: "client-abc")
    }
    guard case .server(status: status, retryAfter: nil) = error else {
      Issue.record("expected .server(\(status)), got \(String(describing: error))")
      return
    }
    #expect(error?.isTransient == true)
  }

  @Test func setupGateIsRecognisedOnOAuthEndpoints() async {
    let transport = FakeHTTPTransport(script: [
      .json(status: 503, #"{"error":"setup_required","message":"Setup.","setupRequired":true,"recoveryMode":false}"#)
    ])
    let error = await thrownOAuthError { () throws(OAuthClientError) in
      try await AuthFixtures.client(transport).register(AuthFixtures.configuration)
    }
    guard case .setupRequired(message: "Setup.") = error else {
      Issue.record("expected .setupRequired, got \(String(describing: error))")
      return
    }
  }

  @Test func transportFailureIsWrapped() async {
    let transport = FakeHTTPTransport(script: [.failure(URLError(.timedOut))])
    let error = await thrownOAuthError { () throws(OAuthClientError) in
      try await AuthFixtures.client(transport).refresh(refreshToken: "old", clientID: "client-abc")
    }
    guard case .transport(let underlying) = error else {
      Issue.record("expected .transport, got \(String(describing: error))")
      return
    }
    #expect((underlying as? URLError)?.code == .timedOut)
    #expect(error?.isTransient == true)
  }

  @Test func revokePostsTokenWithHint() async throws {
    let transport = FakeHTTPTransport(script: [.response(status: 200)])
    try await AuthFixtures.client(transport).revoke(refreshToken: "refresh-1")
    let request = try #require(await transport.requests.first)
    #expect(request.url?.absoluteString == "https://tenant.example.test/api/oauth/revoke")
    #expect(formFields(request) == ["token": "refresh-1", "token_type_hint": "refresh_token"])
  }

  @Test func formEncodingFollowsURLStandard() {
    #expect(FormBody.encode([("a b", "c&d=e"), ("ü", "x*y~z")]) == "a+b=c%26d%3De&%C3%BC=x*y%7Ez")
  }
}

@Suite struct AuthorizationCallbackTests {
  func error(_ url: String, state: String = "xyz") -> AuthError? {
    do {
      _ = try AuthorizationCallback.code(from: URL(string: url)!, expectedState: state)
      return nil
    } catch {
      return error
    }
  }

  @Test func extractsCodeWhenStateMatches() throws {
    let url = URL(string: "com.pljeske.NocturneSync://oauth/callback?code=abc123&state=xyz")!
    #expect(try AuthorizationCallback.code(from: url, expectedState: "xyz") == "abc123")
  }

  @Test func rejectsWrongState() {
    let result = error("com.pljeske.NocturneSync://oauth/callback?code=abc123&state=other")
    guard case .stateMismatch = result else {
      Issue.record("expected .stateMismatch, got \(String(describing: result))")
      return
    }
  }

  @Test func surfacesDenial() {
    let result = error(
      "com.pljeske.NocturneSync://oauth/callback?error=access_denied&error_description=User%20said%20no&state=xyz")
    guard case .authorizationDenied(code: "access_denied", description: "User said no") = result else {
      Issue.record("expected .authorizationDenied, got \(String(describing: result))")
      return
    }
  }

  @Test func rejectsCallbackWithoutCode() {
    let result = error("com.pljeske.NocturneSync://oauth/callback?state=xyz")
    guard case .malformedCallback = result else {
      Issue.record("expected .malformedCallback, got \(String(describing: result))")
      return
    }
  }
}
