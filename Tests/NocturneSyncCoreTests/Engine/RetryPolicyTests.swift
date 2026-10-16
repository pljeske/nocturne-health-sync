import Foundation
import Testing

@testable import NocturneSyncCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct RetryPolicyTests {
  let policy = RetryPolicy(maxAttempts: 6, baseDelay: 1, maxDelay: 8, maxRetryAfter: 15)
  let serverError = NocturneClientError.server(status: 502, retryAfter: nil)

  @Test func ceilingDoublesAndCaps() {
    let ceilings = (1...5).map { policy.delay(afterFailedAttempts: $0, error: serverError, unitRandom: 1) }
    #expect(ceilings == [1, 2, 4, 8, 8])
  }

  @Test func fullJitterScalesFromZeroToCeiling() {
    #expect(policy.delay(afterFailedAttempts: 3, error: serverError, unitRandom: 0) == 0)
    #expect(policy.delay(afterFailedAttempts: 3, error: serverError, unitRandom: 0.25) == 1)
    #expect(policy.delay(afterFailedAttempts: 3, error: serverError, unitRandom: 7) == 4)  // clamped
  }

  @Test func givesUpAfterMaxAttempts() {
    #expect(policy.delay(afterFailedAttempts: 5, error: serverError, unitRandom: 1) != nil)
    #expect(policy.delay(afterFailedAttempts: 6, error: serverError, unitRandom: 1) == nil)
  }

  @Test func retryAfterIsAFloor() {
    let limited = NocturneClientError.rateLimited(retryAfter: 10)
    #expect(policy.delay(afterFailedAttempts: 1, error: limited, unitRandom: 1) == 10)
    let short = NocturneClientError.server(status: 503, retryAfter: 0.5)
    #expect(policy.delay(afterFailedAttempts: 3, error: short, unitRandom: 1) == 4)
  }

  @Test func retryAfterBeyondTheBudgetEndsTheRun() {
    #expect(policy.delay(afterFailedAttempts: 1, error: .rateLimited(retryAfter: 600), unitRandom: 0) == nil)
  }

  @Test func transientErrorsAreRetried() {
    let transient: [NocturneClientError] = [
      .transport(URLError(.timedOut)), .server(status: 500, retryAfter: nil), .rateLimited(retryAfter: nil),
      .auth(.refreshFailed(.server(status: 503, retryAfter: nil))),
    ]
    for error in transient {
      #expect(policy.delay(afterFailedAttempts: 1, error: error, unitRandom: 1) != nil, "\(error)")
    }
  }

  @Test func permanentErrorsAreNot() {
    let permanent: [NocturneClientError] = [
      .badRequest(nil), .unauthorized, .forbidden(nil), .setupRequired(message: nil),
      .recoveryModeActive(message: nil), .unexpectedStatus(404, nil), .cancelled, .auth(.signedOut),
    ]
    for error in permanent {
      #expect(policy.delay(afterFailedAttempts: 1, error: error, unitRandom: 1) == nil, "\(error)")
    }
  }
}
