import Foundation
import NocturneSyncCore
import Synchronization
import Testing

@testable import NocturneSyncFeatures

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum Fixtures {
  static let instance = URL(string: "https://alice.nocturne.example")!
  static let now = Date(timeIntervalSince1970: 1_760_000_000)
  static let scheme = "com.pljeske.NocturneSync"

  static func pending(state: String = "st4te") -> PendingAuthorization {
    PendingAuthorization(
      url: URL(string: "https://alice.nocturne.example/api/oauth/authorize?state=\(state)")!,
      clientID: "client-abc", state: state, pkce: PKCE())
  }

  static func report(_ results: [HealthDataType: PipelineResult]) -> SyncReport {
    var report = SyncReport(startedAt: now, finishedAt: now)
    report.results = results
    return report
  }
}

actor FakeAuthService: AuthService {
  enum Call: Equatable {
    case begin
    case complete(URL)
    case signOut
  }

  private(set) var calls: [Call] = []
  private var signedIn: Bool
  private var beginError: AuthError?
  private var completeError: AuthError?
  private var signOutError: AuthError?

  init(signedIn: Bool = false) {
    self.signedIn = signedIn
  }

  func failBegin(with error: AuthError) { beginError = error }
  func failComplete(with error: AuthError) { completeError = error }
  func failSignOut(with error: AuthError) { signOutError = error }

  var isSignedIn: Bool { signedIn }

  func beginAuthorization() async throws(AuthError) -> PendingAuthorization {
    calls.append(.begin)
    if let beginError { throw beginError }
    return Fixtures.pending()
  }

  func completeAuthorization(callbackURL: URL, pending: PendingAuthorization) async throws(AuthError) {
    calls.append(.complete(callbackURL))
    if let completeError { throw completeError }
    signedIn = true
  }

  func signOut() async throws(AuthError) {
    calls.append(.signOut)
    signedIn = false
    if let signOutError { throw signOutError }
  }
}

actor FakeSyncService: SyncService {
  nonisolated let events: AsyncStream<SyncEvent>
  private nonisolated let sink: AsyncStream<SyncEvent>.Continuation
  private(set) var reasons: [SyncReason] = []
  private(set) var cancelCount = 0
  var state: SyncState? = SyncState()
  private var reports: [SyncReport] = []
  private var gate: CheckedContinuation<Void, Never>?
  private var holdNext = false

  init() {
    (events, sink) = AsyncStream.makeStream(of: SyncEvent.self)
  }

  nonisolated func emit(_ event: SyncEvent) { sink.yield(event) }

  func setState(_ state: SyncState?) { self.state = state }
  func enqueue(_ report: SyncReport) { reports.append(report) }
  func holdNextRun() { holdNext = true }
  var isHolding: Bool { gate != nil }
  func release() {
    gate?.resume()
    gate = nil
  }

  func sync(reason: SyncReason) async -> SyncReport {
    reasons.append(reason)
    if holdNext {
      holdNext = false
      await withCheckedContinuation { gate = $0 }
    }
    return reports.isEmpty
      ? Fixtures.report([.heartRate: .completed, .stepCount: .completed, .sleep: .completed]) : reports.removeFirst()
  }

  func cancelCurrentRun() async { cancelCount += 1 }
  func persistedState() async -> SyncState? { state }
}

/// The parts of `HealthSource` the app model uses; the query methods are never called by it.
actor FakeHealth: HealthSource {
  private(set) var authorizationRequests = 0
  private(set) var deliveryEnabled: [HealthDataType] = []
  private var observers: [HealthDataType: @Sendable () async -> Void] = [:]
  private var authorizationError: HealthSourceError?

  var observedTypes: [HealthDataType] { observers.keys.sorted { $0.rawValue < $1.rawValue } }
  func failAuthorization(with error: HealthSourceError) { authorizationError = error }

  func simulateChange(of type: HealthDataType) async {
    await observers[type]?()
  }

  func requestReadAuthorization() async throws(HealthSourceError) {
    authorizationRequests += 1
    if let authorizationError { throw authorizationError }
  }

  func heartRateSamples(after anchor: Data?, startingAt start: Date, limit: Int) async throws(HealthSourceError)
    -> HeartRatePage
  {
    Issue.record("the app model must not query Health directly")
    return HeartRatePage(samples: [], anchor: Data(), mightHaveMore: false)
  }

  func stepTotals(in interval: DateInterval, bucketSeconds: Int) async throws(HealthSourceError) -> [StepBucketTotal] {
    Issue.record("the app model must not query Health directly")
    return []
  }

  func sleepSamples(overlapping interval: DateInterval) async throws(HealthSourceError) -> [SleepSample] {
    Issue.record("the app model must not query Health directly")
    return []
  }

  func biometricSamples(in interval: DateInterval) async throws(HealthSourceError) -> [BiometricSample] {
    Issue.record("the app model must not query Health directly")
    return []
  }

  func enableBackgroundDelivery(for type: HealthDataType) async throws(HealthSourceError) {
    deliveryEnabled.append(type)
  }

  func observeChanges(of type: HealthDataType, onChange: @escaping @Sendable () async -> Void)
    async throws(HealthSourceError)
  {
    observers[type] = onChange
  }
}

final class FakeScheduler: BackgroundScheduling {
  private let dates = Mutex<[Date]>([])
  var scheduled: [Date] { dates.withLock { $0 } }
  func scheduleRefresh(earliestBegin: Date) { dates.withLock { $0.append(earliestBegin) } }
}

final class InMemorySettings: SettingsStore {
  private let url: Mutex<URL?>
  init(_ url: URL? = nil) { self.url = Mutex(url) }
  func instanceURL() -> URL? { url.withLock { $0 } }
  func setInstanceURL(_ url: URL?) { self.url.withLock { $0 = url } }
}

/// Answers with a redirect carrying `code` and the state from the authorization URL, or an error.
@MainActor
final class FakeAuthenticator: WebAuthenticating {
  private(set) var requests: [(url: URL, scheme: String)] = []
  var error: WebAuthenticationError?

  func authenticate(url: URL, callbackScheme: String) async throws(WebAuthenticationError) -> URL {
    requests.append((url, callbackScheme))
    if let error { throw error }
    let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value
    return URL(string: "\(callbackScheme)://oauth/callback?code=c0de&state=\(state ?? "")")!
  }
}

final class URLRecorder: Sendable {
  private let urls = Mutex<[URL]>([])
  var all: [URL] { urls.withLock { $0 } }
  func record(_ url: URL) { urls.withLock { $0.append(url) } }
}

/// Builds an `AppModel` over fakes and records which instances got services.
@MainActor
struct ModelHarness {
  let settings: InMemorySettings
  let health = FakeHealth()
  let scheduler = FakeScheduler()
  let auth: FakeAuthService
  let sync = FakeSyncService()
  let made = URLRecorder()
  let model: AppModel

  init(savedInstance: URL? = Fixtures.instance, signedIn: Bool = true) {
    let settings = InMemorySettings(savedInstance)
    let auth = FakeAuthService(signedIn: signedIn)
    self.settings = settings
    self.auth = auth
    let sync = self.sync
    let made = self.made
    model = AppModel(
      dependencies: AppDependencies(
        settings: settings, health: health, backgroundScheduler: scheduler, callbackScheme: Fixtures.scheme,
        backgroundRefreshInterval: 3600, now: { Fixtures.now },
        makeServices: { url in
          made.record(url)
          return InstanceServices(auth: auth, sync: sync)
        }))
  }

  var instancesMade: [URL] { made.all }
}
