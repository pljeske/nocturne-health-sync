import Foundation

/// Where an instance's anchors and sync state live: one directory per instance base URL, so signing
/// in to a different instance starts a fresh backfill instead of reusing another server's progress,
/// and switching back resumes where that instance left off.
public enum StoreLocation {
  /// `<root>/instances/<first 16 hex digits of SHA-256(baseURL.absoluteString)>`.
  public static func directory(for baseURL: URL, under root: URL) -> URL {
    let digest = SHA256Digest.hash(Array(baseURL.absoluteString.utf8))
    let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return root.appending(path: "instances").appending(path: name)
  }
}
