import Foundation

/// Persists `SyncState`. Only `SyncEngine` writes it. A missing file reads as the default state; a file
/// that cannot be decoded is reported as `FileStoreError.corrupt` so the engine can decide to start over.
public protocol SyncStateStore: Sendable {
  func load() throws -> SyncState
  func save(_ state: SyncState) throws
}

/// `state.json` in `directory`, ISO 8601 dates, written atomically with first-unlock protection.
public struct FileSyncStateStore: SyncStateStore {
  public let fileURL: URL

  public init(directory: URL) {
    fileURL = directory.appending(path: "state.json")
  }

  public func load() throws -> SyncState {
    guard let data = try ProtectedFile.read(fileURL) else { return SyncState() }
    let state: SyncState
    do {
      state = try Self.decoder.decode(SyncState.self, from: data)
    } catch {
      throw FileStoreError.corrupt(fileURL, underlying: error)
    }
    guard state.version <= SyncState.currentVersion else {
      throw FileStoreError.corrupt(fileURL, underlying: UnsupportedVersion(found: state.version))
    }
    return state
  }

  public func save(_ state: SyncState) throws {
    let data: Data
    do {
      data = try Self.encoder.encode(state)
    } catch {
      throw FileStoreError.write(fileURL, underlying: error)
    }
    try ProtectedFile.write(data, to: fileURL)
  }

  public struct UnsupportedVersion: Error, Sendable, Equatable {
    public let found: Int
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
