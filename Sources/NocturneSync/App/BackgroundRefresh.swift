import BackgroundTasks
import Foundation
import NocturneSyncFeatures
import os

/// The `BGAppRefreshTask` fallback for when Health background delivery is late or throttled.
///
/// Apple behaviour relied on (device only; the simulator does not run BG tasks on its own):
/// - The handler must be registered before `didFinishLaunching` returns, for an identifier listed in
///   `BGTaskSchedulerPermittedIdentifiers`.
/// - Submitting a request for an identifier that already has a pending request replaces it, so
///   rescheduling after every run keeps exactly one pending.
/// - iOS decides when, and whether, a refresh runs; `earliestBeginDate` is only a lower bound.
/// - `expirationHandler` fires shortly before the time runs out; `setTaskCompleted` must still be
///   called, which happens once the cancelled run returns at its next batch boundary.
enum BackgroundRefresh {
  static let identifier = "com.pljeske.NocturneSync.refresh"
  static let logger = Logger(subsystem: "com.pljeske.NocturneSync.App", category: "BackgroundRefresh")

  @MainActor
  static func register(model: AppModel) {
    let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
      guard let refresh = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      let box = RefreshTask(refresh)
      Task { @MainActor in handle(box, model: model) }
    }
    if !registered {
      logger.error("BG task \(identifier, privacy: .public) is not in BGTaskSchedulerPermittedIdentifiers")
    }
  }

  @MainActor
  private static func handle(_ task: RefreshTask, model: AppModel) {
    // Keep one request pending even if this run is killed before it reschedules.
    BGTaskRefreshScheduler().scheduleRefresh(earliestBegin: Date(timeIntervalSinceNow: 3600))
    let work = Task { @MainActor in
      let success = await model.performBackgroundRefresh()
      task.completed(success: success)
    }
    task.onExpiration {
      Task { @MainActor in await model.cancelSync() }
      work.cancel()
    }
  }
}

/// `BGAppRefreshTask` is not annotated `Sendable`. The handler is registered on the main queue, and
/// both members used here (`expirationHandler`, `setTaskCompleted(success:)`) are only touched from
/// the main actor, so the box never sees concurrent access.
private struct RefreshTask: @unchecked Sendable {
  private let task: BGAppRefreshTask

  init(_ task: BGAppRefreshTask) {
    self.task = task
  }

  @MainActor func completed(success: Bool) {
    task.setTaskCompleted(success: success)
  }

  @MainActor func onExpiration(_ handler: @escaping @Sendable () -> Void) {
    task.expirationHandler = handler
  }
}

/// `BackgroundScheduling` on `BGTaskScheduler`.
struct BGTaskRefreshScheduler: BackgroundScheduling {
  func scheduleRefresh(earliestBegin: Date) {
    let request = BGAppRefreshTaskRequest(identifier: BackgroundRefresh.identifier)
    request.earliestBeginDate = earliestBegin
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      // Expected on the simulator and when Background App Refresh is off for the app.
      BackgroundRefresh.logger.error("Could not schedule BG refresh: \(error.localizedDescription, privacy: .public)")
    }
  }
}
