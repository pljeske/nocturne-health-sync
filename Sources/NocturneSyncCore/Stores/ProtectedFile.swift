import Foundation

/// Why a file-backed store failed. `corrupt` is the one the engine may recover from by discarding the
/// file; the others are environmental.
public enum FileStoreError: Error, Sendable {
  case read(URL, underlying: any Error)
  case write(URL, underlying: any Error)
  case remove(URL, underlying: any Error)
  case createDirectory(URL, underlying: any Error)
  /// The file exists but its contents are not what this version of the app writes.
  case corrupt(URL, underlying: any Error)

  public var url: URL {
    switch self {
    case .read(let url, _), .write(let url, _), .remove(let url, _), .createDirectory(let url, _), .corrupt(let url, _):
      url
    }
  }
}

/// Small files written atomically (temporary file in the same directory, then rename, via
/// `Data.WritingOptions.atomic`) and, on iOS, with `completeUntilFirstUserAuthentication` protection so
/// background syncs after a reboot can read them once the device has been unlocked once. The store
/// directory is excluded from backups: anchors are opaque handles into one device's HealthKit store
/// and are meaningless on another, and everything else is rebuilt by one sync.
enum ProtectedFile {
  static func prepareDirectory(_ directory: URL) throws(FileStoreError) {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var directory = directory
      try directory.setResourceValues(values)
    } catch {
      throw .createDirectory(directory, underlying: error)
    }
  }

  /// `nil` when the file does not exist.
  static func read(_ url: URL) throws(FileStoreError) -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      return try Data(contentsOf: url)
    } catch {
      throw .read(url, underlying: error)
    }
  }

  static func write(_ data: Data, to url: URL) throws(FileStoreError) {
    try prepareDirectory(url.deletingLastPathComponent())
    var options: Data.WritingOptions = [.atomic]
    #if os(iOS)
      options.insert(.completeFileProtectionUntilFirstUserAuthentication)
    #endif
    do {
      try data.write(to: url, options: options)
    } catch {
      throw .write(url, underlying: error)
    }
  }

  /// No-op when the file does not exist.
  static func remove(_ url: URL) throws(FileStoreError) {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      throw .remove(url, underlying: error)
    }
  }
}
