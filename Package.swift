// swift-tools-version: 6.0
import PackageDescription

// NocturneSyncCore: domain types, Nocturne client, auth, stores, sync engine.
// NocturneSyncFeatures: the app's view models and launch/sign-in/sync coordination, behind protocols.
// Both are Foundation (+ Observation) only, so they build and test on macOS and Linux; the iOS app
// target adds only HealthKit, Keychain, BackgroundTasks and SwiftUI glue.
let package = Package(
  name: "NocturneSyncCore",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "NocturneSyncCore", targets: ["NocturneSyncCore"]),
    .library(name: "NocturneSyncFeatures", targets: ["NocturneSyncFeatures"]),
  ],
  targets: [
    .target(name: "NocturneSyncCore"),
    .target(name: "NocturneSyncFeatures", dependencies: ["NocturneSyncCore"]),
    .testTarget(
      name: "NocturneSyncCoreTests",
      dependencies: ["NocturneSyncCore"]
    ),
    .testTarget(
      name: "NocturneSyncFeaturesTests",
      dependencies: ["NocturneSyncFeatures", "NocturneSyncCore"]
    ),
    // Against a running Nocturne; every test is skipped unless NOCTURNE_INTEGRATION_URL is set.
    // See docs/integration.md.
    .testTarget(
      name: "NocturneSyncIntegrationTests",
      dependencies: ["NocturneSyncCore"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
