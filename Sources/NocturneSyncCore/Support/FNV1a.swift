/// 64-bit FNV-1a over UTF-8. Used where a digest has to be the same across launches, which Swift's
/// seeded `Hasher` is not. Not cryptographic: a collision only hides one change until the next one.
enum FNV1a {
  static func hexDigest(of text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(hash, radix: 16)
  }
}
