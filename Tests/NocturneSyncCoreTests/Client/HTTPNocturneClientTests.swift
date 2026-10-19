import Foundation
import Testing

@testable import NocturneSyncCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct HTTPNocturneClientTests {
  let baseURL = URL(string: "https://tenant.example.test")!

  func makeClient(_ transport: FakeHTTPTransport, chunkSize: Int = 500) -> HTTPNocturneClient {
    HTTPNocturneClient(
      baseURL: baseURL, transport: transport, chunkSize: chunkSize,
      now: { Date(timeIntervalSince1970: 1_445_412_480) })
  }

  @Test func postsHeartRatesAsJSONArray() async throws {
    let transport = FakeHTTPTransport()
    try await makeClient(transport).uploadHeartRates(Fixtures.heartRates(2))

    let requests = await transport.requests
    let request = try #require(requests.first)
    #expect(requests.count == 1)
    #expect(request.url?.absoluteString == "https://tenant.example.test/api/v4/HeartRate")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(try await transport.bodyCounts == [2])
  }

  @Test func postsStepCountsToTheirEndpoint() async throws {
    let transport = FakeHTTPTransport()
    try await makeClient(transport).uploadStepCounts(Fixtures.stepCounts(1))
    let requests = await transport.requests
    #expect(requests.map { $0.url?.absoluteString } == ["https://tenant.example.test/api/v4/StepCount"])
  }

  @Test func postsSleepSessionsToTheBulkEndpointInSmallerChunks() async throws {
    let transport = FakeHTTPTransport(fallback: .response(status: 201, body: Data("[]".utf8)))
    try await makeClient(transport).uploadSleepSessions(Fixtures.sleepSessions(21))
    let requests = await transport.requests
    #expect(
      requests.map { $0.url?.absoluteString }
        == Array(repeating: "https://tenant.example.test/api/v4/sleep/sessions/bulk", count: 2))
    #expect(try await transport.bodyCounts == [20, 1])
  }

  @Test func baseURLWithTrailingSlashIsJoinedCleanly() async throws {
    let transport = FakeHTTPTransport()
    let client = HTTPNocturneClient(baseURL: URL(string: "https://tenant.example.test/")!, transport: transport)
    try await client.uploadHeartRates(Fixtures.heartRates(1))
    let requests = await transport.requests
    #expect(requests.first?.url?.absoluteString == "https://tenant.example.test/api/v4/HeartRate")
  }

  @Test(arguments: [
    (1, [1]), (499, [499]), (500, [500]), (501, [500, 1]), (1000, [500, 500]), (1001, [500, 500, 1]),
  ])
  func chunksAtFiveHundred(count: Int, expected: [Int]) async throws {
    let transport = FakeHTTPTransport()
    try await makeClient(transport).uploadHeartRates(Fixtures.heartRates(count))
    #expect(try await transport.bodyCounts == expected)
  }

  @Test func chunksPreserveOrderAndContent() async throws {
    let transport = FakeHTTPTransport()
    try await makeClient(transport, chunkSize: 2).uploadHeartRates(Fixtures.heartRates(5))
    let identifiers = try await transport.requests.map { request -> [String] in
      let array = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [[String: Any]])
      return array.map { $0["syncIdentifier"] as! String }
    }
    #expect(identifiers.flatMap { $0 } == Fixtures.heartRates(5).map(\.syncIdentifier))
    #expect(identifiers.map(\.count) == [2, 2, 1])
  }

  @Test func stopsAtTheFirstFailingChunk() async throws {
    let transport = FakeHTTPTransport(script: [.response(status: 200), .response(status: 502)])
    let error = await thrownError { () throws(NocturneClientError) in
      try await makeClient(transport).uploadHeartRates(Fixtures.heartRates(1500))
    }
    guard case .server(status: 502, retryAfter: nil) = error else {
      Issue.record("expected .server(502), got \(String(describing: error))")
      return
    }
    #expect(await transport.requests.count == 2)
  }

  @Test(arguments: [200, 201, 204, 299])
  func anyTwoHundredIsSuccess(status: Int) async throws {
    let transport = FakeHTTPTransport(script: [.response(status: status)])
    try await makeClient(transport).uploadHeartRates(Fixtures.heartRates(1))
  }

  @Test func badRequestCarriesProblemDetails() async {
    let transport = FakeHTTPTransport(script: [
      .json(
        status: 400,
        """
        {"type":"https://tools.ietf.org/html/rfc9110#section-15.5.1","title":"Bad Request","status":400,\
        "detail":"Maximum 1000 records per request","traceId":"00-abc-00"}
        """)
    ])
    let error = await thrownError { () throws(NocturneClientError) in
      try await makeClient(transport).uploadHeartRates(Fixtures.heartRates(1))
    }
    guard case .badRequest(let problem) = error else {
      Issue.record("expected .badRequest, got \(String(describing: error))")
      return
    }
    #expect(problem?.detail == "Maximum 1000 records per request")
    #expect(problem?.status == 400)
    #expect(problem?.message == "Maximum 1000 records per request")
  }

  @Test func validationProblemWithoutDetailFallsBackToTitle() {
    let problem = ProblemDetails.decode(
      Data(#"{"title":"One or more validation errors occurred.","status":400,"errors":{"[0].Bpm":["x"]}}"#.utf8))
    #expect(problem?.message == "One or more validation errors occurred.")
  }

  @Test func nonJSONErrorBodyYieldsNoProblemDetails() async {
    let transport = FakeHTTPTransport(script: [.response(status: 400, body: Data("<html>nope</html>".utf8))])
    let error = await thrownError { () throws(NocturneClientError) in
      try await makeClient(transport).uploadHeartRates(Fixtures.heartRates(1))
    }
    guard case .badRequest(nil) = error else {
      Issue.record("expected .badRequest(nil), got \(String(describing: error))")
      return
    }
  }

  @Test func unauthorizedAndForbidden() async {
    for (status, expectUnauthorized) in [(401, true), (403, false)] {
      let transport = FakeHTTPTransport(script: [.response(status: status)])
      let error = await thrownError { () throws(NocturneClientError) in
        try await makeClient(transport).uploadHeartRates(Fixtures.heartRates(1))
      }
      switch (error, expectUnauthorized) {
      case (.unauthorized, true), (.forbidden, false): break
      default: Issue.record("status \(status) mapped to \(String(describing: error))")
      }
    }
  }

  @Test func rateLimitedHonoursRetryAfterSeconds() async {
    let transport = FakeHTTPTransport(script: [.response(status: 429, headers: ["Retry-After": "30"])])
    let error = await thrownError { () throws(NocturneClientError) in
      try await makeClient(transport).uploadHeartRates(Fixtures.heartRates(1))
    }
    guard case .rateLimited(retryAfter: 30) = error else {
      Issue.record("expected .rateLimited(30), got \(String(describing: error))")
      return
    }
    #expect(error?.isTransient == true)
    #expect(error?.retryAfter == 30)
  }

  @Test func serverErrorHonoursRetryAfterHTTPDate() async {
    // Client clock is 07:28:00 GMT; header is two minutes later.
    let transport = FakeHTTPTransport(script: [
      .response(status: 503, headers: ["Retry-After": "Wed, 21 Oct 2015 07:30:00 GMT"], body: Data())
    ])
    let error = await thrownError { () throws(NocturneClientError) in
      try await makeClient(transport).uploadHeartRates(Fixtures.heartRates(1))
    }
    guard case .server(status: 503, retryAfter: 120) = error else {
      Issue.record("expected .server(503, 120), got \(String(describing: error))")
      return
    }
  }

  @Test func setupRequiredIsRecognised() async {
    let transport = FakeHTTPTransport(script: [
      .json(
        status: 503,
        #"{"error":"setup_required","message":"Initial setup required.","setupRequired":true,"recoveryMode":false}"#)
    ])
    let error = await thrownError { () throws(NocturneClientError) in
      try await makeClient(transport).uploadStepCounts(Fixtures.stepCounts(1))
    }
    guard case .setupRequired(message: "Initial setup required.") = error else {
      Issue.record("expected .setupRequired, got \(String(describing: error))")
      return
    }
    #expect(error?.isTransient == false)
  }

  @Test func recoveryModeIsRecognised() async {
    let transport = FakeHTTPTransport(script: [
      .json(
        status: 503,
        #"{"error":"recovery_mode_active","message":"Recovery.","setupRequired":false,"recoveryMode":true}"#)
    ])
    let error = await thrownError { () throws(NocturneClientError) in
      try await makeClient(transport).uploadStepCounts(Fixtures.stepCounts(1))
    }
    guard case .recoveryModeActive(message: "Recovery.") = error else {
      Issue.record("expected .recoveryModeActive, got \(String(describing: error))")
      return
    }
  }

  @Test func plainServiceUnavailableIsAServerError() async {
    let transport = FakeHTTPTransport(script: [.json(status: 503, #"{"title":"Service Unavailable","status":503}"#)])
    let error = await thrownError { () throws(NocturneClientError) in
      try await makeClient(transport).uploadStepCounts(Fixtures.stepCounts(1))
    }
    guard case .server(status: 503, retryAfter: nil) = error else {
      Issue.record("expected .server(503), got \(String(describing: error))")
      return
    }
    #expect(error?.isTransient == true)
  }

  @Test(arguments: [404, 409, 413, 418, 301])
  func undefinedStatusesAreUnexpectedAndFinal(status: Int) async {
    let transport = FakeHTTPTransport(script: [.response(status: status)])
    let error = await thrownError { () throws(NocturneClientError) in
      try await makeClient(transport).uploadHeartRates(Fixtures.heartRates(1))
    }
    guard case .unexpectedStatus(status, nil) = error else {
      Issue.record("expected .unexpectedStatus(\(status)), got \(String(describing: error))")
      return
    }
    #expect(error?.isTransient == false)
  }

  @Test func transportFailureIsWrappedAndTransient() async {
    let transport = FakeHTTPTransport(script: [.failure(URLError(.notConnectedToInternet))])
    let error = await thrownError { () throws(NocturneClientError) in
      try await makeClient(transport).uploadHeartRates(Fixtures.heartRates(1))
    }
    guard case .transport(let underlying) = error else {
      Issue.record("expected .transport, got \(String(describing: error))")
      return
    }
    #expect((underlying as? URLError)?.code == .notConnectedToInternet)
    #expect(error?.isTransient == true)
    #expect(error?.retryAfter == nil)
  }

  @Test func cancelledRequestIsReportedAsCancellation() async {
    for failure: any Error in [URLError(.cancelled), CancellationError()] {
      let transport = FakeHTTPTransport(script: [.failure(failure)])
      let error = await thrownError { () throws(NocturneClientError) in
        try await makeClient(transport).uploadHeartRates(Fixtures.heartRates(1))
      }
      guard case .cancelled = error else {
        Issue.record("expected .cancelled for \(failure), got \(String(describing: error))")
        return
      }
      #expect(error?.isTransient == false)
    }
  }

  @Test func cancelledTaskDoesNotStartTheNextChunk() async {
    let transport = FakeHTTPTransport()
    let client = makeClient(transport, chunkSize: 1)
    let task = Task {
      await thrownError { () throws(NocturneClientError) in
        try await client.uploadHeartRates(Fixtures.heartRates(50))
      }
    }
    task.cancel()
    let error = await task.value
    guard case .cancelled = error else {
      Issue.record("expected .cancelled, got \(String(describing: error))")
      return
    }
    #expect(await transport.requests.count < 50)
  }
}

@Suite struct ChunksTests {
  @Test func emptyCollectionHasNoChunks() {
    #expect([Int]().chunks(ofCount: 3).isEmpty)
  }

  @Test func splitsIntoConsecutiveSlices() {
    #expect(Array(1...7).chunks(ofCount: 3).map(Array.init) == [[1, 2, 3], [4, 5, 6], [7]])
    #expect(Array(1...6).chunks(ofCount: 3).map(Array.init) == [[1, 2, 3], [4, 5, 6]])
  }
}
