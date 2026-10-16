import Foundation
import NocturneSyncCore

/// Sign-in and token ownership for one instance. `AuthSession` is the live implementation.
public protocol AuthService: Sendable {
  var isSignedIn: Bool { get async }
  func beginAuthorization() async throws(AuthError) -> PendingAuthorization
  func completeAuthorization(callbackURL: URL, pending: PendingAuthorization) async throws(AuthError)
  func signOut() async throws(AuthError)
}

extension AuthSession: AuthService {}

/// Syncing for one instance. `SyncEngine` is the live implementation.
public protocol SyncService: Sendable {
  func sync(reason: SyncReason) async -> SyncReport
  func cancelCurrentRun() async
  func persistedState() async -> SyncState?
}

extension SyncEngine: SyncService {}

/// Everything bound to one instance base URL.
public struct InstanceServices: Sendable {
  public var auth: any AuthService
  public var sync: any SyncService

  public init(auth: any AuthService, sync: any SyncService) {
    self.auth = auth
    self.sync = sync
  }
}

public enum WebAuthenticationError: Error, Sendable {
  /// The user closed the sheet. Not an error to show.
  case cancelled
  case failed(String)
}

/// Presents the instance's authorization page and returns the redirect URL. The live implementation
/// wraps SwiftUI's `WebAuthenticationSession` (an `ASWebAuthenticationSession`).
@MainActor
public protocol WebAuthenticating {
  func authenticate(url: URL, callbackScheme: String) async throws(WebAuthenticationError) -> URL
}

/// Schedules the `BGAppRefreshTask` fallback. The live implementation wraps `BGTaskScheduler`.
public protocol BackgroundScheduling: Sendable {
  func scheduleRefresh(earliestBegin: Date)
}

/// The one user setting: the instance base URL.
public protocol SettingsStore: Sendable {
  func instanceURL() -> URL?
  func setInstanceURL(_ url: URL?)
}

/// `SettingsStore` on `UserDefaults`. A fresh `UserDefaults` handle per call keeps the type a plain
/// `Sendable` struct; `UserDefaults` itself is thread-safe.
public struct UserDefaultsSettings: SettingsStore {
  public static let instanceURLKey = "instanceURL"
  private let suiteName: String?

  public init(suiteName: String? = nil) {
    self.suiteName = suiteName
  }

  private var defaults: UserDefaults {
    suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
  }

  public func instanceURL() -> URL? {
    defaults.string(forKey: Self.instanceURLKey).flatMap { URL(string: $0) }
  }

  public func setInstanceURL(_ url: URL?) {
    defaults.set(url?.absoluteString, forKey: Self.instanceURLKey)
  }
}
