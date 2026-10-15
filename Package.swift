// swift-tools-version: 6.0
import PackageDescription

// Pure Swift core of NocturneSync: domain types, Nocturne client, auth, stores, sync engine.
// Foundation only, no HealthKit/Keychain/SwiftUI, so it builds and tests on macOS and Linux.
let package = Package(
  name: "NocturneSyncCore",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "NocturneSyncCore", targets: ["NocturneSyncCore"])
  ],
  targets: [
    .target(name: "NocturneSyncCore"),
    .testTarget(
      name: "NocturneSyncCoreTests",
      dependencies: ["NocturneSyncCore"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
