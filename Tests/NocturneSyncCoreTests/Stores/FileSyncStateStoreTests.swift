import Foundation
import Testing

@testable import NocturneSyncCore

@Suite struct FileSyncStateStoreTests {
  let directory = TemporaryDirectory()
  let now = Date(timeIntervalSince1970: 1_720_000_000)

  func sample() -> SyncState {
    SyncState(
      heartRate: .init(lastSuccessfulSync: now, lastError: nil, uploadedCount: 12345),
      stepCount: .init(
        lastSuccessfulSync: nil,
        lastError: .init(
          message: "Bulk operations are limited to 1000 step count records per request", occurredAt: now),
        uploadedCount: 7),
      stepBackfillCompletedThrough: now.addingTimeInterval(-86400),
      heartRateBackfillComplete: true,
      heartRateBackfillStart: now.addingTimeInterval(-90 * 86400),
      stepLookbackSent: ["steps-1719828000-300": 42])
  }

  @Test func missingFileIsTheDefaultState() throws {
    let store = FileSyncStateStore(directory: directory.url)
    let state = try store.load()
    #expect(state == SyncState())
    #expect(state.version == SyncState.currentVersion)
    #expect(state.heartRate.uploadedCount == 0)
    #expect(state.stepBackfillCompletedThrough == nil)
    #expect(state.stepLookbackSent.isEmpty)
    #expect(!state.heartRateBackfillComplete)
  }

  @Test func roundTrips() throws {
    let store = FileSyncStateStore(directory: directory.url)
    try store.save(sample())
    #expect(try store.load() == sample())
    #expect(directory.contents == ["state.json"])
  }

  @Test func overwriteKeepsTheLatest() throws {
    let store = FileSyncStateStore(directory: directory.url)
    try store.save(sample())
    var updated = sample()
    updated.heartRate.uploadedCount += 1
    try store.save(updated)
    #expect(try store.load() == updated)
    #expect(directory.contents == ["state.json"])
  }

  @Test func onDiskFormatIsStable() throws {
    let store = FileSyncStateStore(directory: directory.url)
    try store.save(sample())
    let json = try String(contentsOf: store.fileURL, encoding: .utf8)
    let expected = """
      {
        "heartRate" : {
          "lastSuccessfulSync" : "2024-07-03T09:46:40Z",
          "uploadedCount" : 12345
        },
        "heartRateBackfillComplete" : true,
        "heartRateBackfillStart" : "2024-04-04T09:46:40Z",
        "stepBackfillCompletedThrough" : "2024-07-02T09:46:40Z",
        "stepCount" : {
          "lastError" : {
            "message" : "Bulk operations are limited to 1000 step count records per request",
            "occurredAt" : "2024-07-03T09:46:40Z"
          },
          "uploadedCount" : 7
        },
        "stepLookbackSent" : {
          "steps-1719828000-300" : 42
        },
        "version" : 1
      }
      """
    #expect(json == expected)
  }

  @Test func corruptFileIsATypedError() throws {
    let store = FileSyncStateStore(directory: directory.url)
    try store.save(sample())
    try Data("{\"version\": 1, \"heartRate\": \"nope\"".utf8).write(to: store.fileURL)
    do {
      _ = try store.load()
      Issue.record("expected a throw")
    } catch let error as FileStoreError {
      guard case .corrupt(let url, _) = error else {
        Issue.record("expected .corrupt, got \(error)")
        return
      }
      #expect(url == store.fileURL)
    } catch {
      Issue.record("expected FileStoreError, got \(error)")
    }
  }

  @Test func newerVersionIsReportedAsCorruptNotMisread() throws {
    let store = FileSyncStateStore(directory: directory.url)
    try store.save(sample())
    let bumped = try String(contentsOf: store.fileURL, encoding: .utf8).replacingOccurrences(
      of: "\"version\" : 1", with: "\"version\" : 2")
    try Data(bumped.utf8).write(to: store.fileURL)
    do {
      _ = try store.load()
      Issue.record("expected a throw")
    } catch let error as FileStoreError {
      guard case .corrupt(_, let underlying) = error else {
        Issue.record("expected .corrupt, got \(error)")
        return
      }
      #expect(underlying as? FileSyncStateStore.UnsupportedVersion == .init(found: 2))
    } catch {
      Issue.record("expected FileStoreError, got \(error)")
    }
  }

  @Test func olderFilesWithoutNewOptionalFieldsStillLoad() throws {
    let store = FileSyncStateStore(directory: directory.url)
    try ProtectedFile.write(
      Data(
        """
        {"version":1,"heartRate":{"uploadedCount":1},"stepCount":{"uploadedCount":2},"heartRateBackfillComplete":false}
        """.utf8), to: store.fileURL)
    let state = try store.load()
    #expect(state.heartRate.uploadedCount == 1)
    #expect(state.stepCount.lastError == nil)
    #expect(state.stepBackfillCompletedThrough == nil)
  }

  @Test func subscriptAddressesTypes() {
    var state = SyncState()
    state[.stepCount].uploadedCount = 3
    state[.heartRate].lastError = .init(message: "x", occurredAt: now)
    #expect(state.stepCount.uploadedCount == 3)
    #expect(state[.heartRate].lastError?.message == "x")
    #expect(state[.stepCount].lastError == nil)
  }
}
