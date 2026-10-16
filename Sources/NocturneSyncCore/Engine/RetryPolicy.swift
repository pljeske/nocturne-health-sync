import Foundation

/// When to retry a failed upload within one run. Exponential backoff with full jitter, capped, and
/// never sooner than a server `Retry-After`. Only transient errors (transport, 5xx, 429, a transient
/// refresh failure) are retried. A `Retry-After` longer than `maxRetryAfter` ends the run instead of
/// sleeping through the little background time iOS grants; the next trigger tries again.
public struct RetryPolicy: Sendable, Hashable {
  /// Attempts per batch, the first one included.
  public var maxAttempts: Int
  /// Ceiling of the first retry delay, doubling per retry.
  public var baseDelay: TimeInterval
  public var maxDelay: TimeInterval
  public var maxRetryAfter: TimeInterval

  /// Worst case without `Retry-After`: 1 + 2 + 4 s of sleep over four attempts, inside one background
  /// execution.
  public static let `default` = RetryPolicy(maxAttempts: 4, baseDelay: 1, maxDelay: 8, maxRetryAfter: 15)

  public init(maxAttempts: Int, baseDelay: TimeInterval, maxDelay: TimeInterval, maxRetryAfter: TimeInterval) {
    precondition(maxAttempts >= 1, "at least one attempt")
    self.maxAttempts = maxAttempts
    self.baseDelay = baseDelay
    self.maxDelay = maxDelay
    self.maxRetryAfter = maxRetryAfter
  }

  /// Seconds to wait before the next attempt, or nil to give up.
  /// - Parameters:
  ///   - failedAttempts: attempts made so far, all failed (1 after the first failure).
  ///   - unitRandom: a value in `[0, 1]` that scales the delay ceiling (full jitter).
  public func delay(afterFailedAttempts failedAttempts: Int, error: NocturneClientError, unitRandom: Double)
    -> TimeInterval?
  {
    guard error.isTransient, failedAttempts < maxAttempts else { return nil }
    let exponent = Double(min(max(failedAttempts - 1, 0), 30))
    let ceiling = min(maxDelay, baseDelay * pow(2, exponent))
    let jittered = ceiling * min(max(unitRandom, 0), 1)
    guard let retryAfter = error.retryAfter else { return jittered }
    guard retryAfter <= maxRetryAfter else { return nil }
    return max(jittered, retryAfter)
  }
}

/// Applies a `RetryPolicy` to one upload operation.
struct Retrier: Sendable {
  let policy: RetryPolicy
  let sleep: @Sendable (TimeInterval) async throws -> Void
  let unitRandom: @Sendable () -> Double

  func run(_ operation: () async throws(NocturneClientError) -> Void) async throws(NocturneClientError) {
    var failedAttempts = 0
    while true {
      do {
        try await operation()
        return
      } catch {
        failedAttempts += 1
        guard
          let delay = policy.delay(afterFailedAttempts: failedAttempts, error: error, unitRandom: unitRandom())
        else { throw error }
        do {
          try await sleep(delay)
        } catch {
          throw .cancelled
        }
        guard !Task.isCancelled else { throw .cancelled }
      }
    }
  }
}
