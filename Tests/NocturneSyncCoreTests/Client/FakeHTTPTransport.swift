import Foundation

@testable import NocturneSyncCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Scripted transport: answers requests from `script` in order, then with `fallback` forever. Records
/// every request it saw.
actor FakeHTTPTransport: HTTPTransport {
  enum Reply {
    case response(status: Int, headers: [String: String] = [:], body: Data = Data())
    case failure(any Error)

    static func json(status: Int, headers: [String: String] = [:], _ json: String) -> Reply {
      .response(status: status, headers: headers, body: Data(json.utf8))
    }
  }

  private(set) var requests: [URLRequest] = []
  private var script: [Reply]
  private let fallback: Reply

  init(script: [Reply] = [], fallback: Reply = .response(status: 200, body: Data("[]".utf8))) {
    self.script = script
    self.fallback = fallback
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let reply = script.isEmpty ? fallback : script.removeFirst()
    switch reply {
    case .failure(let error):
      throw error
    case .response(let status, let headers, let body):
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      return (body, response)
    }
  }

  /// Number of JSON array elements in each request body, in request order.
  var bodyCounts: [Int] {
    get throws {
      try requests.map { request in
        let array = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [Any]
        return array?.count ?? -1
      }
    }
  }
}
