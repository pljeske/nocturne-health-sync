import Foundation

/// Why the auth layer could not produce a usable access token or complete sign-in.
public enum AuthError: Error, Sendable {
  /// No grant: never signed in, signed out, or the refresh token was rejected with `invalid_grant`
  /// (expired after 90 idle days, replayed, or revoked in Nocturne). The user has to sign in again.
  case signedOut
  /// Dynamic client registration failed; nothing was cached.
  case registrationFailed(OAuthClientError)
  /// The browser flow came back with `error=...` (typically `access_denied`).
  case authorizationDenied(code: String, description: String?)
  /// The callback's `state` is not the one this flow started with. Ignored as a stale or forged redirect.
  case stateMismatch
  /// The callback URL carries neither a code nor an error.
  case malformedCallback
  /// Code-for-token exchange failed.
  case exchangeFailed(OAuthClientError)
  /// Refresh failed for a reason other than `invalid_grant`. Tokens are kept; retry later.
  case refreshFailed(OAuthClientError)
  /// Local sign-out succeeded but the server could not be told to revoke the grant.
  case revokeFailed(OAuthClientError)
  /// The token store failed.
  case storage(any Error)

  /// Whether a later identical attempt may succeed without user action.
  public var isTransient: Bool {
    switch self {
    case .registrationFailed(let error), .exchangeFailed(let error), .refreshFailed(let error),
      .revokeFailed(let error):
      error.isTransient
    case .signedOut, .authorizationDenied, .stateMismatch, .malformedCallback, .storage: false
    }
  }
}

/// Owns the current `TokenSet` for one Nocturne instance. The only writer of the `TokenStore`.
///
/// Refresh is single-flight: concurrent callers that find the access token expired await one shared
/// refresh task, so the rotating refresh token is never sent twice (a replay revokes the whole grant).
/// The rotated token set is persisted before any caller gets the new access token, so a crash right
/// after a refresh cannot leave a dead refresh token on disk.
public actor AuthSession {
  /// Access tokens with less than this many seconds left are refreshed up front.
  public static let accessTokenLeeway: TimeInterval = 60

  public let client: OAuthClient
  public let configuration: OAuthConfiguration
  private let store: any TokenStore
  private let now: @Sendable () -> Date

  private var tokens: TokenSet?
  /// Set when the newest token set is in memory but the store rejected it; retried on the next access.
  private var needsPersist = false
  private var refreshTask: Task<TokenSet, any Error>?

  /// Loads the persisted token set, if any. A store failure here leaves the session signed out rather
  /// than throwing: the UI will offer sign-in, and the next save will report the store problem.
  public init(
    client: OAuthClient, configuration: OAuthConfiguration, store: any TokenStore,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.client = client
    self.configuration = configuration
    self.store = store
    self.now = now
    self.tokens = try? store.loadTokens()
  }

  public var isSignedIn: Bool { tokens != nil }

  // MARK: Sign-in

  /// Step 1 of sign-in: resolves the `client_id` (cached, else one registration) and builds the
  /// authorization URL with a fresh PKCE pair and state.
  public func beginAuthorization() async throws(AuthError) -> PendingAuthorization {
    let clientID = try await resolveClientID()
    let pkce = PKCE()
    let state = AuthorizationCallback.randomState()
    let url = client.authorizationURL(clientID: clientID, configuration: configuration, state: state, pkce: pkce)
    return PendingAuthorization(url: url, clientID: clientID, state: state, pkce: pkce)
  }

  /// Step 2 of sign-in: validates the callback, exchanges the code, persists and adopts the tokens.
  public func completeAuthorization(callbackURL: URL, pending: PendingAuthorization) async throws(AuthError) {
    let code = try AuthorizationCallback.code(from: callbackURL, expectedState: pending.state)
    let fresh: TokenSet
    do {
      fresh = try await client.exchange(
        code: code, pkce: pending.pkce, clientID: pending.clientID, configuration: configuration)
    } catch {
      throw .exchangeFailed(error)
    }
    try adopt(fresh)
  }

  /// Clears the grant locally first, then asks the server to revoke it. The session is signed out even
  /// when this throws `revokeFailed`.
  public func signOut() async throws(AuthError) {
    let previous = tokens
    refreshTask?.cancel()
    refreshTask = nil
    try clearTokens()
    guard let previous else { return }
    do {
      try await client.revoke(refreshToken: previous.refreshToken)
    } catch {
      throw .revokeFailed(error)
    }
  }

  // MARK: Access tokens

  /// A bearer token valid for at least `accessTokenLeeway` seconds, refreshing first if needed.
  public func validAccessToken() async throws(AuthError) -> String {
    guard let current = tokens else { throw .signedOut }
    if needsPersist { try persist(current) }
    if current.isAccessTokenValid(at: now(), leeway: Self.accessTokenLeeway) {
      return current.accessToken
    }
    return try await refreshedTokens().accessToken
  }

  /// Called by `AuthenticatedTransport` after a 401. If another caller already replaced
  /// `rejectedAccessToken`, the replacement is returned without a network round trip; otherwise one
  /// refresh is performed (shared with any concurrent caller).
  public func refreshAfterUnauthorized(rejectedAccessToken: String) async throws(AuthError) -> String {
    guard let current = tokens else { throw .signedOut }
    if current.accessToken != rejectedAccessToken {
      return current.accessToken
    }
    return try await refreshedTokens().accessToken
  }

  // MARK: Internals

  private func resolveClientID() async throws(AuthError) -> String {
    let cached: String?
    do {
      cached = try store.loadClientID(for: client.baseURL)
    } catch {
      throw .storage(error)
    }
    if let cached { return cached }
    let registered: String
    do {
      registered = try await client.register(configuration)
    } catch {
      throw .registrationFailed(error)
    }
    do {
      try store.saveClientID(registered, for: client.baseURL)
    } catch {
      throw .storage(error)
    }
    return registered
  }

  private func refreshedTokens() async throws(AuthError) -> TokenSet {
    let task: Task<TokenSet, any Error>
    if let running = refreshTask {
      task = running
    } else {
      task = Task { try await self.performRefresh() }
      refreshTask = task
    }
    defer { if refreshTask == task { refreshTask = nil } }
    do {
      return try await task.value
    } catch let error as AuthError {
      throw error
    } catch {
      // The task body throws only AuthError; cancellation of the awaiting caller surfaces here.
      throw .refreshFailed(.cancelled)
    }
  }

  private func performRefresh() async throws(AuthError) -> TokenSet {
    guard let current = tokens else { throw .signedOut }
    let clientID: String
    do {
      guard let cached = try store.loadClientID(for: client.baseURL) else { throw AuthError.signedOut }
      clientID = cached
    } catch let error as AuthError {
      throw error
    } catch {
      throw .storage(error)
    }
    let fresh: TokenSet
    do {
      fresh = try await client.refresh(refreshToken: current.refreshToken, clientID: clientID)
    } catch .invalidGrant {
      try clearTokens()
      throw .signedOut
    } catch {
      throw .refreshFailed(error)
    }
    try adopt(fresh)
    return fresh
  }

  /// Makes `fresh` current. The in-memory copy is updated even when the store fails, because the
  /// previous refresh token is already dead on the server; the store is retried on the next access.
  private func adopt(_ fresh: TokenSet) throws(AuthError) {
    tokens = fresh
    try persist(fresh)
  }

  private func persist(_ set: TokenSet) throws(AuthError) {
    do {
      try store.saveTokens(set)
      needsPersist = false
    } catch {
      needsPersist = true
      throw .storage(error)
    }
  }

  private func clearTokens() throws(AuthError) {
    tokens = nil
    needsPersist = false
    do {
      try store.clearTokens()
    } catch {
      throw .storage(error)
    }
  }
}
