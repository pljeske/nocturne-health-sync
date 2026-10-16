import Foundation

public enum InstanceURLError: Error, Equatable, Sendable {
  case empty
  case malformed
  /// Plain http to anything but this machine.
  case insecure
  case hasQueryOrFragment
  case hasCredentials

  public var message: String {
    switch self {
    case .empty: "Enter the address of your Nocturne instance."
    case .malformed: "That does not look like a web address."
    case .insecure: "Use an https:// address. Plain http is only allowed for localhost."
    case .hasQueryOrFragment: "Enter the instance address without ? or # parts."
    case .hasCredentials: "Enter the address without a user name or password."
    }
  }
}

/// Turns what the user typed into the instance base URL: https assumed when no scheme is given,
/// scheme and host lower-cased, trailing slashes dropped, so the same instance always yields the same
/// URL (tokens, client ids and stores are keyed by it).
public enum InstanceURL {
  public static func parse(_ input: String) throws(InstanceURLError) -> URL {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw .empty }
    let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
    guard var components = URLComponents(string: candidate),
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(), !host.isEmpty
    else { throw .malformed }
    guard components.user == nil, components.password == nil else { throw .hasCredentials }
    guard components.query == nil, components.fragment == nil else { throw .hasQueryOrFragment }
    switch scheme {
    case "https": break
    case "http" where isLoopback(host): break
    case "http": throw .insecure
    default: throw .malformed
    }
    components.scheme = scheme
    components.host = host
    var path = components.path
    while path.hasSuffix("/") { path.removeLast() }
    components.path = path
    guard let url = components.url else { throw .malformed }
    return url
  }

  static func isLoopback(_ host: String) -> Bool {
    host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1"
      || host == "[::1]"
  }
}
