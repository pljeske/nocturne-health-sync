import Foundation
import NocturneSyncCore
import Testing

@testable import NocturneSyncFeatures

/// Polls `condition` on the main actor until it holds, failing after about a second.
@MainActor
func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
  for _ in 0..<1000 {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(1))
  }
  Issue.record("condition never became true", sourceLocation: sourceLocation)
}

@MainActor
@Suite struct AppModelProgressTests {
  let now = Fixtures.now

  @Test func progressEventsDriveLiveActivityAndCounts() async throws {
    let harness = ModelHarness()
    await harness.model.launch()
    let model = harness.model

    harness.sync.emit(.started(.heartRate))
    try await waitUntil { model.activity == [SyncProgress(type: .heartRate)] }

    let progress = SyncProgress(type: .heartRate, uploaded: 2000, reached: now)
    harness.sync.emit(.progressed(progress, SyncState(heartRate: .init(uploadedCount: 2000))))
    try await waitUntil { model.activity == [progress] }
    #expect(model.statuses.first { $0.type == .heartRate }?.uploadedCount == 2000)

    harness.sync.emit(.finished(.heartRate))
    try await waitUntil { model.activity.isEmpty }
  }

  @Test func activityIsOrderedByType() async throws {
    let harness = ModelHarness()
    await harness.model.launch()
    let model = harness.model
    harness.sync.emit(.started(.stepCount))
    harness.sync.emit(.started(.heartRate))
    try await waitUntil { model.activity.count == 2 }
    #expect(model.activity.map(\.type) == [.heartRate, .stepCount])
  }

  @Test func eventsAreIgnoredWhileSignedOut() async throws {
    let harness = ModelHarness()
    await harness.model.launch()
    await harness.model.signOut()
    harness.sync.emit(.started(.heartRate))
    harness.sync.emit(.progressed(SyncProgress(type: .heartRate, uploaded: 5), SyncState()))
    try await Task.sleep(for: .milliseconds(20))
    #expect(harness.model.activity.isEmpty)
    #expect(harness.model.statuses.isEmpty)
  }

  @Test func signOutClearsActivity() async throws {
    let harness = ModelHarness()
    await harness.model.launch()
    let model = harness.model
    harness.sync.emit(.started(.stepCount))
    try await waitUntil { !model.activity.isEmpty }
    await model.signOut()
    #expect(model.activity.isEmpty)
  }
}
