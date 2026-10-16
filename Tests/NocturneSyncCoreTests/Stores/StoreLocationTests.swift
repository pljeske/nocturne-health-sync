import Foundation
import Testing

@testable import NocturneSyncCore

@Suite struct StoreLocationTests {
  let root = URL(filePath: "/var/mobile/Library/Application Support/Sync")

  @Test func isStablePerInstanceAndDistinctAcrossInstances() {
    let a = URL(string: "https://alice.nocturne.example")!
    let b = URL(string: "https://bob.nocturne.example")!
    let first = StoreLocation.directory(for: a, under: root)
    #expect(first == StoreLocation.directory(for: a, under: root))
    #expect(first != StoreLocation.directory(for: b, under: root))
    #expect(first.deletingLastPathComponent().lastPathComponent == "instances")
    #expect(first.lastPathComponent.count == 16)
    #expect(first.path.hasPrefix(root.path))
  }

  @Test func nameIsTheSHA256Prefix() {
    // SHA-256("https://example.test") begins with these bytes; pinned so a refactor cannot silently
    // move every installed app's state.
    let directory = StoreLocation.directory(for: URL(string: "https://example.test")!, under: root)
    let expected = SHA256Digest.hash(Array("https://example.test".utf8)).prefix(8)
      .map { String(format: "%02x", $0) }.joined()
    #expect(directory.lastPathComponent == expected)
  }
}
