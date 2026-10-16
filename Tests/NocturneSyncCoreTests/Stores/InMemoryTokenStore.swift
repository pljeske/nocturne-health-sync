import Foundation
import Synchronization

@testable import NocturneSyncCore

/// `TokenStore` in memory, recording every call so tests can assert ordering, with an injectable
/// failure for the save path. Tokens and client ids are kept per instance base URL.
final class InMemoryTokenStore: TokenStore {
  enum Event: Equatable {
    case loadTokens(URL)
    case saveTokens(TokenSet, URL)
    case clearTokens(URL)
    case loadClientID(URL)
    case saveClientID(String, URL)
  }

  struct Failure: Error, Equatable {}

  private struct State {
    var tokens: [URL: TokenSet]
    var clientIDs: [URL: String]
    var events: [Event] = []
    var failSaves = false
  }

  private let state: Mutex<State>

  init(tokensByInstance: [URL: TokenSet] = [:], clientIDs: [URL: String] = [:]) {
    state = Mutex(State(tokens: tokensByInstance, clientIDs: clientIDs))
  }

  /// Tokens stored for `AuthFixtures.baseURL`, the instance most tests use.
  convenience init(tokens: TokenSet?, clientIDs: [URL: String] = [:]) {
    self.init(tokensByInstance: tokens.map { [AuthFixtures.baseURL: $0] } ?? [:], clientIDs: clientIDs)
  }

  var tokens: TokenSet? { tokens(for: AuthFixtures.baseURL) }
  func tokens(for baseURL: URL) -> TokenSet? { state.withLock { $0.tokens[baseURL] } }
  var events: [Event] { state.withLock { $0.events } }
  var failSaves: Bool {
    get { state.withLock { $0.failSaves } }
    set { state.withLock { $0.failSaves = newValue } }
  }

  func loadTokens(for baseURL: URL) throws -> TokenSet? {
    state.withLock {
      $0.events.append(.loadTokens(baseURL))
      return $0.tokens[baseURL]
    }
  }

  func saveTokens(_ tokens: TokenSet, for baseURL: URL) throws {
    try state.withLock {
      $0.events.append(.saveTokens(tokens, baseURL))
      if $0.failSaves { throw Failure() }
      $0.tokens[baseURL] = tokens
    }
  }

  func clearTokens(for baseURL: URL) throws {
    state.withLock {
      $0.events.append(.clearTokens(baseURL))
      $0.tokens[baseURL] = nil
    }
  }

  func loadClientID(for baseURL: URL) throws -> String? {
    state.withLock {
      $0.events.append(.loadClientID(baseURL))
      return $0.clientIDs[baseURL]
    }
  }

  func saveClientID(_ clientID: String, for baseURL: URL) throws {
    try state.withLock {
      $0.events.append(.saveClientID(clientID, baseURL))
      if $0.failSaves { throw Failure() }
      $0.clientIDs[baseURL] = clientID
    }
  }
}
