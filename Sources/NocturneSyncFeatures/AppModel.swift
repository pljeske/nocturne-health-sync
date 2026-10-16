import Foundation
import NocturneSyncCore
import Observation

/// What the app needs from the platform. The app target fills this with HealthKit, Keychain,
/// URLSession and BackgroundTasks; tests fill it with fakes.
public struct AppDependencies: Sendable {
  public var settings: any SettingsStore
  public var health: any HealthSource
  public var backgroundScheduler: any BackgroundScheduling
  /// Scheme of the OAuth redirect URI (the bundle id).
  public var callbackScheme: String
  /// How far ahead to ask for the `BGAppRefreshTask` fallback after each run.
  public var backgroundRefreshInterval: TimeInterval
  public var now: @Sendable () -> Date
  /// Builds the auth session and sync engine for one instance. Called once per instance URL.
  public var makeServices: @Sendable (URL) -> InstanceServices

  public init(
    settings: any SettingsStore,
    health: any HealthSource,
    backgroundScheduler: any BackgroundScheduling,
    callbackScheme: String,
    backgroundRefreshInterval: TimeInterval = 3600,
    now: @escaping @Sendable () -> Date = Date.init,
    makeServices: @escaping @Sendable (URL) -> InstanceServices
  ) {
    self.settings = settings
    self.health = health
    self.backgroundScheduler = backgroundScheduler
    self.callbackScheme = callbackScheme
    self.backgroundRefreshInterval = backgroundRefreshInterval
    self.now = now
    self.makeServices = makeServices
  }
}

/// The app's single source of truth: signed-in state, status rows, and every entry point that leads
/// to a sync (launch, foreground, Health observer, background refresh, "Sync now").
@MainActor
@Observable
public final class AppModel {
  public enum Phase: Sendable, Equatable {
    case signedOut(instance: URL?)
    case signedIn(instance: URL)
  }

  public private(set) var phase: Phase
  public private(set) var statuses: [DataTypeStatus] = []
  public private(set) var isSigningIn = false
  public private(set) var isSyncing = false
  /// Shown once, then cleared by the view.
  public var message: UserMessage?
  /// Bound to the instance address field.
  public var instanceText: String

  @ObservationIgnored private let dependencies: AppDependencies
  @ObservationIgnored private var cached: (url: URL, services: InstanceServices)?
  @ObservationIgnored private var observersStarted = false
  @ObservationIgnored private var runningSyncs = 0

  public init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    let saved = dependencies.settings.instanceURL()
    phase = .signedOut(instance: saved)
    instanceText = saved?.absoluteString ?? ""
  }

  // MARK: Lifecycle

  /// Call at every launch, from `application(_:didFinishLaunchingWithOptions:)`, including background
  /// launches for Health delivery: observers and background delivery must be registered each launch.
  public func launch() async {
    guard case .signedOut(let instance?) = phase else { return }
    guard await services(for: instance).auth.isSignedIn else { return }
    phase = .signedIn(instance: instance)
    await startHealthObservers()
    await refreshStatus()
  }

  /// The app came to the foreground. Asks for Health access (HealthKit shows the sheet only when it
  /// has not been answered) and syncs everything.
  public func becameActive() async {
    guard case .signedIn = phase else { return }
    await requestHealthAccess()
    await run(.launch)
  }

  // MARK: Sign-in

  public func signIn(using authenticator: some WebAuthenticating) async {
    guard case .signedOut = phase, !isSigningIn else { return }
    let instance: URL
    do {
      instance = try InstanceURL.parse(instanceText)
    } catch {
      message = UserMessage(error.message)
      return
    }

    isSigningIn = true
    defer { isSigningIn = false }
    let auth = services(for: instance).auth
    do {
      let pending = try await auth.beginAuthorization()
      let callback = try await authenticator.authenticate(url: pending.url, callbackScheme: dependencies.callbackScheme)
      try await auth.completeAuthorization(callbackURL: callback, pending: pending)
    } catch let error as AuthError {
      message = UserMessage(error)
      return
    } catch let error as WebAuthenticationError {
      if case .failed(let reason) = error { message = UserMessage("Sign-in failed: \(reason)") }
      return
    } catch {
      message = UserMessage("Sign-in failed: \(error)")
      return
    }

    dependencies.settings.setInstanceURL(instance)
    instanceText = instance.absoluteString
    phase = .signedIn(instance: instance)
    await requestHealthAccess()
    await startHealthObservers()
    await run(.launch)
  }

  /// Signs out locally first (tokens are cleared even when the server cannot be reached), then asks
  /// the server to revoke the grant. Sync progress is kept, so signing in again resumes.
  public func signOut() async {
    guard case .signedIn(let instance) = phase else { return }
    let services = services(for: instance)
    await services.sync.cancelCurrentRun()
    do {
      try await services.auth.signOut()
    } catch {
      message = UserMessage(error)
    }
    phase = .signedOut(instance: instance)
    statuses = []
  }

  // MARK: Syncing

  public func syncNow() async {
    await run(.manual)
  }

  /// `BGAppRefreshTask` handler. Returns whether every data type completed.
  public func performBackgroundRefresh() async -> Bool {
    guard let report = await run(.backgroundRefresh) else { return false }
    return report.results.values.allSatisfy { if case .completed = $0 { true } else { false } }
  }

  /// Background time is up: stop at the next batch boundary.
  public func cancelSync() async {
    guard case .signedIn(let instance) = phase else { return }
    await services(for: instance).sync.cancelCurrentRun()
  }

  public func refreshStatus() async {
    guard case .signedIn(let instance) = phase else {
      statuses = []
      return
    }
    if let state = await services(for: instance).sync.persistedState() {
      statuses = DataTypeStatus.make(from: state)
    }
  }

  func healthDidChange(_ type: HealthDataType) async {
    await run(.healthChange(type))
  }

  @discardableResult
  private func run(_ reason: SyncReason) async -> SyncReport? {
    guard case .signedIn(let instance) = phase else { return nil }
    let sync = services(for: instance).sync
    runningSyncs += 1
    isSyncing = true
    defer {
      runningSyncs -= 1
      isSyncing = runningSyncs > 0
    }

    let report = await sync.sync(reason: reason)
    dependencies.backgroundScheduler.scheduleRefresh(
      earliestBegin: dependencies.now().addingTimeInterval(dependencies.backgroundRefreshInterval))
    if report.results.values.contains(where: Self.isSignedOut), case .signedIn(instance) = phase {
      phase = .signedOut(instance: instance)
      statuses = []
      message = UserMessage(AuthError.signedOut)
      return report
    }
    await refreshStatus()
    return report
  }

  private static func isSignedOut(_ result: PipelineResult) -> Bool {
    if case .failed(.upload(.auth(.signedOut))) = result { true } else { false }
  }

  // MARK: Health

  private func requestHealthAccess() async {
    do {
      try await dependencies.health.requestReadAuthorization()
    } catch {
      message = UserMessage(error)
    }
  }

  /// Registers background delivery and an observer per type, once per launch. The observer runs only
  /// its own type; the HealthKit source calls HealthKit's completion handler after it returns.
  private func startHealthObservers() async {
    guard !observersStarted else { return }
    observersStarted = true
    for type in HealthDataType.allCases {
      do {
        try await dependencies.health.enableBackgroundDelivery(for: type)
        try await dependencies.health.observeChanges(of: type) { [weak self] in
          await self?.healthDidChange(type)
        }
      } catch {
        message = UserMessage(error)
      }
    }
  }

  private func services(for instance: URL) -> InstanceServices {
    if let cached, cached.url == instance { return cached.services }
    let made = dependencies.makeServices(instance)
    cached = (instance, made)
    return made
  }
}
