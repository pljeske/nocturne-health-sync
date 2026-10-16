import AuthenticationServices
import NocturneSyncFeatures
import SwiftUI

/// `WebAuthenticating` over SwiftUI's `WebAuthenticationSession`, which presents an
/// `ASWebAuthenticationSession` from the current window and returns the redirect URL.
struct SwiftUIWebAuthenticator: WebAuthenticating {
  let session: WebAuthenticationSession

  func authenticate(url: URL, callbackScheme: String) async throws(WebAuthenticationError) -> URL {
    do {
      return try await session.authenticate(
        using: url, callback: .customScheme(callbackScheme), preferredBrowserSession: nil, additionalHeaderFields: [:])
    } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
      throw .cancelled
    } catch {
      throw .failed(error.localizedDescription)
    }
  }
}
