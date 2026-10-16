import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Upload side of the Nocturne V4 API. Callers pass non-empty arrays of any size; the implementation
/// is responsible for the server's per-request limit. Delivery is at-least-once: a thrown error means
/// some chunks may already be on the server, and the caller re-sends everything next time, relying
/// on the server's upsert by `(dataSource, syncIdentifier)`.
public protocol NocturneClient: Sendable {
  func uploadHeartRates(_ records: [HeartRateRecord]) async throws(NocturneClientError)
  func uploadStepCounts(_ records: [StepCountRecord]) async throws(NocturneClientError)
}

/// Live client over an `HTTPTransport`. Knows nothing about authentication: the bearer header and the
/// 401 refresh path belong to the transport it is given (`AuthenticatedTransport`, auth layer).
public struct HTTPNocturneClient: NocturneClient {
  /// Tenant URL, e.g. `https://<slug>.<base-domain>`.
  public let baseURL: URL
  private let transport: any HTTPTransport
  private let chunkSize: Int
  private let now: @Sendable () -> Date

  /// - Parameters:
  ///   - chunkSize: records per request; must not exceed `NocturneAPI.maxRecordsPerRequest`.
  ///   - now: clock used to turn an HTTP-date `Retry-After` into a delay. Injectable for tests.
  public init(
    baseURL: URL,
    transport: any HTTPTransport,
    chunkSize: Int = NocturneAPI.uploadChunkSize,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    precondition(
      (1...NocturneAPI.maxRecordsPerRequest).contains(chunkSize),
      "chunkSize must be in 1...\(NocturneAPI.maxRecordsPerRequest)")
    self.baseURL = baseURL
    self.transport = transport
    self.chunkSize = chunkSize
    self.now = now
  }

  public func uploadHeartRates(_ records: [HeartRateRecord]) async throws(NocturneClientError) {
    try await upload(records.map(HeartRateRequestBody.init), to: NocturneAPI.heartRatePath)
  }

  public func uploadStepCounts(_ records: [StepCountRecord]) async throws(NocturneClientError) {
    try await upload(records.map(StepCountRequestBody.init), to: NocturneAPI.stepCountPath)
  }

  /// Sends `bodies` in order, `chunkSize` per request, and stops at the first failure. Checks for
  /// cancellation before each request so a cancelled run does not start a doomed upload.
  private func upload(_ bodies: [some Encodable], to path: String) async throws(NocturneClientError) {
    precondition(!bodies.isEmpty, "upload called with no records; the server rejects an empty array")
    for chunk in bodies.chunks(ofCount: chunkSize) {
      guard !Task.isCancelled else { throw .cancelled }
      try await post(Array(chunk), to: path)
    }
  }

  private func post(_ chunk: [some Encodable], to path: String) async throws(NocturneClientError) {
    var request = URLRequest(url: baseURL.appending(path: path))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    do {
      request.httpBody = try RequestEncoder.encode(chunk)
    } catch {
      throw .encoding(error)
    }

    let body: Data
    let response: HTTPURLResponse
    do {
      (body, response) = try await transport.send(request)
    } catch is CancellationError {
      throw .cancelled
    } catch let error as URLError where error.code == .cancelled {
      throw .cancelled
    } catch let error as AuthError {
      throw .auth(error)
    } catch {
      throw .transport(error)
    }

    guard (200..<300).contains(response.statusCode) else {
      throw NocturneClientError(rejecting: response, body: body, now: now())
    }
  }
}
