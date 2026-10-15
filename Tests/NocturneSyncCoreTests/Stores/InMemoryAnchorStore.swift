import Foundation
import Synchronization

@testable import NocturneSyncCore

/// `AnchorStore` in memory, recording saves so engine tests can assert when the anchor was committed.
final class InMemoryAnchorStore: AnchorStore {
  struct Failure: Error, Equatable {}

  private struct State {
    var anchors: [HealthDataType: Data] = [:]
    var saves: [(HealthDataType, Data)] = []
    var failSaves = false
  }

  private let state: Mutex<State>

  init(anchors: [HealthDataType: Data] = [:]) {
    state = Mutex(State(anchors: anchors))
  }

  var anchors: [HealthDataType: Data] { state.withLock { $0.anchors } }
  var saves: [(HealthDataType, Data)] { state.withLock { $0.saves } }
  var failSaves: Bool {
    get { state.withLock { $0.failSaves } }
    set { state.withLock { $0.failSaves = newValue } }
  }

  func loadAnchor(for type: HealthDataType) throws -> Data? {
    state.withLock { $0.anchors[type] }
  }

  func saveAnchor(_ anchor: Data, for type: HealthDataType) throws {
    try state.withLock {
      $0.saves.append((type, anchor))
      if $0.failSaves { throw Failure() }
      $0.anchors[type] = anchor
    }
  }

  func clearAnchor(for type: HealthDataType) throws {
    state.withLock { _ = $0.anchors.removeValue(forKey: type) }
  }
}
