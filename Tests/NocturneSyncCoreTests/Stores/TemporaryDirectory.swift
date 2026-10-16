import Foundation

/// A fresh directory under the system temporary directory, removed when the value goes away.
final class TemporaryDirectory {
  let url: URL

  init() {
    url = FileManager.default.temporaryDirectory.appending(path: "NocturneSyncTests-\(UUID().uuidString)")
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }

  var contents: [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.sorted() ?? []
  }
}
