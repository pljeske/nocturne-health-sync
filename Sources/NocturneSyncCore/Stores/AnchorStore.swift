import Foundation

/// Persists the opaque `HKQueryAnchor` archive per data type. The core never sees HealthKit: the app's
/// `HealthSource` archives and unarchives the anchor, the engine stores the bytes. Only `SyncEngine`
/// writes it, and only after every record derived from the previous anchor has been uploaded.
public protocol AnchorStore: Sendable {
  func loadAnchor(for type: HealthDataType) throws -> Data?
  func saveAnchor(_ anchor: Data, for type: HealthDataType) throws
  /// Forgets the anchor so the next query starts over (used on sign-out and when the archive cannot be
  /// unarchived).
  func clearAnchor(for type: HealthDataType) throws
}

/// One file per data type in `directory`, written atomically with first-unlock protection.
public struct FileAnchorStore: AnchorStore {
  public let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  func fileURL(for type: HealthDataType) -> URL {
    directory.appending(path: "\(type.rawValue).anchor")
  }

  public func loadAnchor(for type: HealthDataType) throws -> Data? {
    try ProtectedFile.read(fileURL(for: type))
  }

  public func saveAnchor(_ anchor: Data, for type: HealthDataType) throws {
    try ProtectedFile.write(anchor, to: fileURL(for: type))
  }

  public func clearAnchor(for type: HealthDataType) throws {
    try ProtectedFile.remove(fileURL(for: type))
  }
}
