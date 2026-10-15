import Foundation
import Testing

@testable import NocturneSyncCore

@Suite struct FileAnchorStoreTests {
  let directory = TemporaryDirectory()

  @Test func missingAnchorIsNil() throws {
    let store = FileAnchorStore(directory: directory.url)
    #expect(try store.loadAnchor(for: .heartRate) == nil)
    #expect(try store.loadAnchor(for: .stepCount) == nil)
  }

  @Test func roundTripsPerTypeAndCreatesTheDirectory() throws {
    let store = FileAnchorStore(directory: directory.url.appending(path: "nested/deeper"))
    try store.saveAnchor(Data([1, 2, 3]), for: .heartRate)
    try store.saveAnchor(Data([9]), for: .stepCount)
    #expect(try store.loadAnchor(for: .heartRate) == Data([1, 2, 3]))
    #expect(try store.loadAnchor(for: .stepCount) == Data([9]))
  }

  @Test func overwriteLeavesExactlyOneCompleteFile() throws {
    let store = FileAnchorStore(directory: directory.url)
    try store.saveAnchor(Data(repeating: 0xAA, count: 4096), for: .heartRate)
    try store.saveAnchor(Data(repeating: 0xBB, count: 10), for: .heartRate)
    #expect(try store.loadAnchor(for: .heartRate) == Data(repeating: 0xBB, count: 10))
    #expect(directory.contents == ["heartRate.anchor"])
  }

  @Test func clearRemovesOnlyThatType() throws {
    let store = FileAnchorStore(directory: directory.url)
    try store.saveAnchor(Data([1]), for: .heartRate)
    try store.saveAnchor(Data([2]), for: .stepCount)
    try store.clearAnchor(for: .heartRate)
    try store.clearAnchor(for: .heartRate)  // idempotent
    #expect(try store.loadAnchor(for: .heartRate) == nil)
    #expect(try store.loadAnchor(for: .stepCount) == Data([2]))
    #expect(directory.contents == ["stepCount.anchor"])
  }

  @Test func fileNamesAreStable() {
    let store = FileAnchorStore(directory: URL(filePath: "/x"))
    #expect(store.fileURL(for: .heartRate).lastPathComponent == "heartRate.anchor")
    #expect(store.fileURL(for: .stepCount).lastPathComponent == "stepCount.anchor")
  }

  #if canImport(Darwin)
    // Linux Foundation accepts the attribute but cannot read it back, so this is verified on Apple only.
    @Test func directoryIsExcludedFromBackup() throws {
      let store = FileAnchorStore(directory: directory.url)
      try store.saveAnchor(Data([1]), for: .heartRate)
      let values = try directory.url.resourceValues(forKeys: [.isExcludedFromBackupKey])
      #expect(values.isExcludedFromBackup == true)
    }
  #endif

  @Test func unwritableLocationIsATypedError() {
    let store = FileAnchorStore(directory: URL(filePath: "/dev/null/impossible"))
    do {
      try store.saveAnchor(Data([1]), for: .heartRate)
      Issue.record("expected a throw")
    } catch let error as FileStoreError {
      guard case .createDirectory = error else {
        Issue.record("expected .createDirectory, got \(error)")
        return
      }
    } catch {
      Issue.record("expected FileStoreError, got \(error)")
    }
  }
}
