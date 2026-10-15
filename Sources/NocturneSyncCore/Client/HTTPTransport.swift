import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// The single seam between the client and auth layers and the network. An implementation hands back
/// whatever HTTP response it got, unchanged; interpreting status codes is the caller's job. Errors
/// thrown here mean no HTTP response was obtained at all.
public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Live transport over `URLSession`.
public struct URLSessionTransport: HTTPTransport {
  public enum Failure: Error, Sendable {
    /// `URLSession` returned a response that is not `HTTPURLResponse`; cannot happen for http(s) URLs.
    case nonHTTPResponse
  }

  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw Failure.nonHTTPResponse }
    return (data, http)
  }
}
