import NocturneSyncFeatures
import SwiftUI

struct SignInView: View {
  @Bindable var model: AppModel
  let authenticator: SwiftUIWebAuthenticator

  var body: some View {
    Form {
      Section {
        TextField("https://you.nocturne.example", text: $model.instanceText)
          .textContentType(.URL)
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .submitLabel(.go)
          .onSubmit(signIn)
      } header: {
        Text("Nocturne instance")
      } footer: {
        Text(
          "NocturneSync uploads heart rate, step count and sleep from Apple Health to this instance. It only reads Health and never writes to it."
        )
      }
      Section {
        Button(action: signIn) {
          if model.isSigningIn {
            ProgressView()
          } else {
            Text("Sign in")
          }
        }
        .disabled(model.isSigningIn || model.instanceText.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .navigationTitle("NocturneSync")
  }

  private func signIn() {
    Task { await model.signIn(using: authenticator) }
  }
}
