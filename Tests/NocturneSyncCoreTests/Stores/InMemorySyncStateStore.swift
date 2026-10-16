import Foundation
import Synchronization

@testable import NocturneSyncCore

/// `SyncStateStore` in memory, keeping every saved state in order.
final class InMemorySyncStateStore: SyncStateStore {
  struct Failure: Error, Equatable {}

  private struct State {
    var current: SyncState
    var history: [SyncState] = []
    var loadError: (any Error)?
    var failSaves = false
  }

  private let state: Mutex<State>

  init(_ initial: SyncState = SyncState()) {
    state = Mutex(State(current: initial))
  }

  var current: SyncState { state.withLock { $0.current } }
  var history: [SyncState] { state.withLock { $0.history } }
  /// Thrown by every `load()` while set.
  var loadError: (any Error)? {
    get { state.withLock { $0.loadError } }
    set { state.withLock { $0.loadError = newValue } }
  }
  var failSaves: Bool {
    get { state.withLock { $0.failSaves } }
    set { state.withLock { $0.failSaves = newValue } }
  }

  func load() throws -> SyncState {
    try state.withLock {
      if let error = $0.loadError { throw error }
      return $0.current
    }
  }

  func save(_ newState: SyncState) throws {
    try state.withLock {
      if $0.failSaves { throw Failure() }
      $0.current = newState
      $0.history.append(newState)
    }
  }
}
