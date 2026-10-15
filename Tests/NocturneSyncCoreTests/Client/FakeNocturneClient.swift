import Foundation

@testable import NocturneSyncCore

/// Records every upload and answers from a script of per-call outcomes, then succeeds forever. Shared
/// by the engine tests in later steps.
actor FakeNocturneClient: NocturneClient {
  enum Call: Equatable {
    case heartRates([HeartRateRecord])
    case stepCounts([StepCountRecord])
  }

  private(set) var calls: [Call] = []
  private var script: [NocturneClientError?]

  /// `script[i]` is the error the i-th call throws; nil means success. Calls past the script succeed.
  init(script: [NocturneClientError?] = []) {
    self.script = script
  }

  func uploadHeartRates(_ records: [HeartRateRecord]) async throws(NocturneClientError) {
    calls.append(.heartRates(records))
    try answer()
  }

  func uploadStepCounts(_ records: [StepCountRecord]) async throws(NocturneClientError) {
    calls.append(.stepCounts(records))
    try answer()
  }

  private func answer() throws(NocturneClientError) {
    guard !script.isEmpty, let error = script.removeFirst() else { return }
    throw error
  }
}
