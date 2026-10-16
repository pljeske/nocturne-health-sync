import NocturneSyncFeatures
import SwiftUI

@main
struct NocturneSyncApp: App {
  // The delegate owns the model: background launches (Health delivery, BG refresh) never create a scene,
  // so launch work cannot live in a view.
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup {
      RootView(model: appDelegate.model)
    }
  }
}
