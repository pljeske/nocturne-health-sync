import Foundation
import Testing

@testable import NocturneSyncFeatures

@Suite struct InstanceURLTests {
  @Test(arguments: [
    ("alice.nocturne.example", "https://alice.nocturne.example"),
    ("https://Alice.Nocturne.Example/", "https://alice.nocturne.example"),
    ("  HTTPS://alice.nocturne.example//  ", "https://alice.nocturne.example"),
    ("https://alice.nocturne.example:8443", "https://alice.nocturne.example:8443"),
    ("https://example.org/nocturne/", "https://example.org/nocturne"),
    ("http://localhost:1610", "http://localhost:1610"),
    ("http://alice.localhost:1610/", "http://alice.localhost:1610"),
    ("http://127.0.0.1:1610", "http://127.0.0.1:1610"),
  ])
  func normalises(input: String, expected: String) throws {
    #expect(try InstanceURL.parse(input).absoluteString == expected)
  }

  @Test(arguments: [
    ("", InstanceURLError.empty),
    ("   ", .empty),
    ("http://nocturne.example", .insecure),
    ("ftp://nocturne.example", .malformed),
    ("https://", .malformed),
    ("https://nocturne.example/?tenant=a", .hasQueryOrFragment),
    ("https://nocturne.example/#x", .hasQueryOrFragment),
    ("https://user:pw@nocturne.example", .hasCredentials),
  ])
  func rejects(input: String, expected: InstanceURLError) {
    #expect(throws: expected) { try InstanceURL.parse(input) }
  }

  @Test func sameInstanceAlwaysYieldsTheSameURL() throws {
    let variants = ["alice.nocturne.example", "https://ALICE.nocturne.example/", "https://alice.nocturne.example"]
    #expect(Set(try variants.map { try InstanceURL.parse($0) }).count == 1)
  }
}

@Suite struct UserDefaultsSettingsTests {
  @Test func roundTripsAndClears() {
    let suite = "NocturneSyncFeaturesTests-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let settings = UserDefaultsSettings(suiteName: suite)
    #expect(settings.instanceURL() == nil)
    settings.setInstanceURL(URL(string: "https://alice.nocturne.example")!)
    #expect(UserDefaultsSettings(suiteName: suite).instanceURL() == URL(string: "https://alice.nocturne.example")!)
    settings.setInstanceURL(nil)
    #expect(settings.instanceURL() == nil)
  }
}
