import Foundation

@testable import NocturneSyncCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Holds every request until `release()` so tests can have several callers genuinely in flight at
/// once. Answers each held request with the same scripted reply.
actor GatedTransport: HTTPTransport {
  private(set) var requests: [URLRequest] = []
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var released = false
  private let reply: FakeHTTPTransport.Reply

  init(reply: FakeHTTPTransport.Reply) {
    self.reply = reply
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    if !released {
      await withCheckedContinuation { waiters.append($0) }
    }
    switch reply {
    case .failure(let error):
      throw error
    case .response(let status, let headers, let body):
      return (
        body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      )
    }
  }

  func release() {
    released = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }

  var heldCount: Int { waiters.count }
}
