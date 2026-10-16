import NocturneSyncFeatures
import UIKit

/// Launch entry point for foreground and background launches alike. Two things must happen before
/// `didFinishLaunching` returns, every launch: the BG task handler is registered (BGTaskScheduler
/// requires it), and Health observers plus background delivery are re-registered (they do not
/// survive relaunch or reinstall). `AppModel.launch()` does the latter once it has confirmed a
/// sign-in exists.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
  // Lazy: a main-actor default value on an NSObject subclass would need a main-actor `init()`
  // overriding NSObject's nonisolated one. First access is on the main actor (didFinishLaunching).
  lazy var model: AppModel = LiveEnvironment.makeModel()

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    BackgroundRefresh.register(model: model)
    let model = model
    Task { await model.launch() }
    return true
  }
}
