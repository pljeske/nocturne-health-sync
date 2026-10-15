import Foundation
import Synchronization

@testable import NocturneSyncCore

/// `TokenStore` in memory, recording every call so tests can assert ordering, with an injectable
/// failure for the save path.
final class InMemoryTokenStore: TokenStore {
  enum Event: Equatable {
    case loadTokens
    case saveTokens(TokenSet)
    case clearTokens
    case loadClientID(URL)
    case saveClientID(String, URL)
  }

  struct Failure: Error, Equatable {}

  private struct State {
    var tokens: TokenSet?
    var clientIDs: [URL: String] = [:]
    var events: [Event] = []
    var failSaves = false
  }

  private let state: Mutex<State>

  init(tokens: TokenSet? = nil, clientIDs: [URL: String] = [:]) {
    state = Mutex(State(tokens: tokens, clientIDs: clientIDs))
  }

  var tokens: TokenSet? { state.withLock { $0.tokens } }
  var events: [Event] { state.withLock { $0.events } }
  var failSaves: Bool {
    get { state.withLock { $0.failSaves } }
    set { state.withLock { $0.failSaves = newValue } }
  }

  func loadTokens() throws -> TokenSet? {
    state.withLock {
      $0.events.append(.loadTokens)
      return $0.tokens
    }
  }

  func saveTokens(_ tokens: TokenSet) throws {
    try state.withLock {
      $0.events.append(.saveTokens(tokens))
      if $0.failSaves { throw Failure() }
      $0.tokens = tokens
    }
  }

  func clearTokens() throws {
    state.withLock {
      $0.events.append(.clearTokens)
      $0.tokens = nil
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
