import Foundation

@testable import NocturneSyncCore

/// Records every upload and answers from a script of per-call outcomes, then succeeds forever. Shared
/// by the engine tests in later steps.
actor FakeNocturneClient: NocturneClient {
  enum Call: Equatable {
    case heartRates([HeartRateRecord])
    case stepCounts([StepCountRecord])
    case sleepSessions([SleepSessionRecord])
  }

  private(set) var calls: [Call] = []
  private var script: [NocturneClientError?]
  private let onCall: (@Sendable (Int) async -> Void)?

  /// `script[i]` is the error the i-th call throws; nil means success. Calls past the script succeed.
  /// `onCall` runs with the zero-based call index before each call is answered, inside the caller's
  /// task, so a test can cancel or hold the run mid-upload.
  init(script: [NocturneClientError?] = [], onCall: (@Sendable (Int) async -> Void)? = nil) {
    self.script = script
    self.onCall = onCall
  }

  var heartRateBatches: [[HeartRateRecord]] {
    calls.compactMap { if case .heartRates(let records) = $0 { records } else { nil } }
  }

  var stepCountBatches: [[StepCountRecord]] {
    calls.compactMap { if case .stepCounts(let records) = $0 { records } else { nil } }
  }

  func uploadHeartRates(_ records: [HeartRateRecord]) async throws(NocturneClientError) {
    let index = calls.count
    calls.append(.heartRates(records))
    await onCall?(index)
    try answer()
  }

  func uploadStepCounts(_ records: [StepCountRecord]) async throws(NocturneClientError) {
    let index = calls.count
    calls.append(.stepCounts(records))
    await onCall?(index)
    try answer()
  }

  var sleepBatches: [[SleepSessionRecord]] {
    calls.compactMap { if case .sleepSessions(let records) = $0 { records } else { nil } }
  }

  func uploadSleepSessions(_ records: [SleepSessionRecord]) async throws(NocturneClientError) {
    let index = calls.count
    calls.append(.sleepSessions(records))
    await onCall?(index)
    try answer()
  }

  private func answer() throws(NocturneClientError) {
    guard !script.isEmpty, let error = script.removeFirst() else { return }
    throw error
  }
}
