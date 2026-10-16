import AuthenticationServices
import NocturneSyncFeatures
import SwiftUI

struct RootView: View {
  @Bindable var model: AppModel
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession

  var body: some View {
    NavigationStack {
      switch model.phase {
      case .signedOut:
        SignInView(model: model, authenticator: SwiftUIWebAuthenticator(session: webAuthenticationSession))
      case .signedIn(let instance):
        StatusView(model: model, instance: instance)
      }
    }
    .alert(
      "NocturneSync",
      isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } }),
      presenting: model.message
    ) { _ in
      Button("OK") {}
    } message: { message in
      Text(message.text)
    }
    .onChange(of: scenePhase, initial: true) { _, phase in
      if phase == .active {
        Task { await model.becameActive() }
      }
    }
  }
}
