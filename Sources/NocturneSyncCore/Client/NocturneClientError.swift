import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Why an upload did not succeed. One case per distinct reaction the sync engine has to take; the
/// `CLAUDE.md` "Auth" and "Sync semantics" sections define those reactions.
public enum NocturneClientError: Error, Sendable {
  /// 400. The request itself is wrong, which for a well-formed record array means a bug in this app
  /// (or a contract change on the server). Never retried.
  case badRequest(ProblemDetails?)
  /// 401 that survived the auth layer's single refresh-and-retry. The grant is unusable.
  case unauthorized
  /// 403. The token lacks the `heartrate.readwrite` / `stepcount.readwrite` scope. Stop syncing and
  /// surface to the user.
  case forbidden(ProblemDetails?)
  /// 503 with `error: setup_required`. The instance has no configured account yet.
  case setupRequired(message: String?)
  /// 503 with `error: recovery_mode_active`. The instance is in account recovery.
  case recoveryModeActive(message: String?)
  /// 429. Retry after `retryAfter` seconds when the server said so.
  case rateLimited(retryAfter: TimeInterval?)
  /// Any other 5xx, including a 503 that is not one of the two above.
  case server(status: Int, retryAfter: TimeInterval?)
  /// A status the contract does not define (other 4xx, 3xx, 1xx). Not retried.
  case unexpectedStatus(Int, ProblemDetails?)
  /// No HTTP response was obtained: DNS, TLS, connection, timeout. Retried with backoff.
  case transport(any Error)
  /// The record array could not be serialised. Cannot happen for records built by the mappers; a
  /// programmer error, never retried.
  case encoding(any Error)
  /// The surrounding task was cancelled before or during the request. Not an error to record.
  case cancelled
  /// The auth layer could not supply a bearer token (see `AuthError`). `.auth(.signedOut)` means stop
  /// syncing until the user signs in again.
  case auth(AuthError)

  /// Whether a later identical attempt may succeed without any change on the client. The retry policy
  /// retries exactly these.
  public var isTransient: Bool {
    switch self {
    case .rateLimited, .server, .transport: true
    case .auth(let error): error.isTransient
    case .badRequest, .unauthorized, .forbidden, .setupRequired, .recoveryModeActive, .unexpectedStatus, .encoding,
      .cancelled:
      false
    }
  }

  /// Server-provided minimum delay before the next attempt, in seconds.
  public var retryAfter: TimeInterval? {
    switch self {
    case .rateLimited(let retryAfter), .server(_, let retryAfter): retryAfter
    default: nil
    }
  }

  /// Classifies a non-2xx response. `now` anchors a `Retry-After` given as an HTTP date.
  init(rejecting response: HTTPURLResponse, body: Data, now: Date) {
    let status = response.statusCode
    precondition(!(200..<300).contains(status), "2xx is success, not an error")
    let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap {
      RetryAfter.seconds(from: $0, now: now)
    }

    switch status {
    case 400: self = .badRequest(ProblemDetails.decode(body))
    case 401: self = .unauthorized
    case 403: self = .forbidden(ProblemDetails.decode(body))
    case 429: self = .rateLimited(retryAfter: retryAfter)
    case 503:
      let unavailable = ServiceUnavailableBody.decode(body)
      switch unavailable?.error {
      case "setup_required": self = .setupRequired(message: unavailable?.message)
      case "recovery_mode_active": self = .recoveryModeActive(message: unavailable?.message)
      default: self = .server(status: status, retryAfter: retryAfter)
      }
    case 500..<600: self = .server(status: status, retryAfter: retryAfter)
    default: self = .unexpectedStatus(status, ProblemDetails.decode(body))
    }
  }
}
