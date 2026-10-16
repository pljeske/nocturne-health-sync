import Foundation
import Testing

@testable import NocturneSyncCore

@Suite struct PKCETests {
  @Test func matchesRFC7636AppendixB() {
    let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  }

  @Test func randomVerifierHasRFCShape() {
    let pkce = PKCE()
    #expect(pkce.verifier.count == 43)
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    #expect(pkce.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
    #expect(pkce.challenge.count == 43)
    #expect(PKCE().verifier != pkce.verifier)
  }

  // FIPS 180-4 vectors plus boundary lengths for the padding logic (55, 56, 64 bytes).
  @Test(arguments: [
    ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
    ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
    (
      "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    ),
    (String(repeating: "a", count: 55), "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"),
    (String(repeating: "a", count: 56), "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"),
    (String(repeating: "a", count: 64), "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"),
    (String(repeating: "a", count: 1000), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"),
  ])
  func sha256MatchesKnownVectors(message: String, hex: String) {
    let digest = SHA256Digest.hash(Array(message.utf8))
    #expect(digest.map { String(format: "%02x", $0) }.joined() == hex)
  }

  @Test func base64URLHasNoPaddingOrUnsafeCharacters() {
    #expect(Base64URL.encode([0xfb, 0xff]) == "-_8")
    #expect(Base64URL.encode([]) == "")
    #expect(Base64URL.encode([0x00]) == "AA")
  }
}
