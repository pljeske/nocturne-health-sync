import Foundation
import NocturneSyncCore
import NocturneSyncFeatures

/// Composition root: the only place that knows which concrete type backs each protocol.
enum LiveEnvironment {
  static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.pljeske.NocturneSync"

  static var marketingVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  }

  @MainActor
  static func makeModel() -> AppModel {
    let health = HealthKitSource()
    let tokens = KeychainTokenStore(service: bundleIdentifier)
    // The URL scheme is the bundle id: reverse-DNS with a dot, as Nocturne's registration requires,
    // and listed in CFBundleURLTypes (project.yml).
    let oauth = OAuthConfiguration(
      softwareID: bundleIdentifier,
      softwareVersion: marketingVersion,
      redirectURI: URL(string: "\(bundleIdentifier)://oauth/callback")!)
    let storeRoot = URL.applicationSupportDirectory.appending(path: "Sync")
    let app = NocturneConstants.appIdentifier(version: marketingVersion)

    return AppModel(
      dependencies: AppDependencies(
        settings: UserDefaultsSettings(),
        health: health,
        backgroundScheduler: BGTaskRefreshScheduler(),
        callbackScheme: bundleIdentifier,
        makeServices: { instance in
          let network = URLSessionTransport()
          let session = AuthSession(
            client: OAuthClient(baseURL: instance, transport: network), configuration: oauth, store: tokens)
          let client = HTTPNocturneClient(
            baseURL: instance, transport: AuthenticatedTransport(base: network, session: session))
          let directory = StoreLocation.directory(for: instance, under: storeRoot)
          let engine = SyncEngine(
            health: health,
            client: client,
            anchors: FileAnchorStore(directory: directory),
            stateStore: FileSyncStateStore(directory: directory),
            pipelines: [HeartRatePipeline(), StepsPipeline(device: NocturneConstants.stepDevice)],
            app: app)
          return InstanceServices(auth: session, sync: engine)
        }))
  }
}
