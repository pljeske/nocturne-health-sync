import Foundation

/// RFC 9457 Problem Details, the error body of every Nocturne V4 endpoint. Fields the server may add
/// (ASP.NET validation `errors`, `traceId`) are ignored.
public struct ProblemDetails: Sendable, Hashable, Decodable {
  public var type: String?
  public var title: String?
  public var status: Int?
  public var detail: String?
  public var instance: String?

  public init(
    type: String? = nil, title: String? = nil, status: Int? = nil, detail: String? = nil, instance: String? = nil
  ) {
    self.type = type
    self.title = title
    self.status = status
    self.detail = detail
    self.instance = instance
  }

  /// `detail` when present, else `title`. ASP.NET model validation problems carry only a title.
  public var message: String? { detail ?? title }

  /// Lenient decode: a body that is not Problem Details (empty, HTML from a proxy) yields nil rather
  /// than an error, because the status code alone already determines what the client does.
  static func decode(_ data: Data) -> ProblemDetails? {
    guard !data.isEmpty else { return nil }
    return try? JSONDecoder().decode(ProblemDetails.self, from: data)
  }
}

/// Body of the 503 that `TenantSetupMiddleware` answers with while the instance is not usable:
/// `{ "error": "setup_required" | "recovery_mode_active", "message": "...", "setupRequired": Bool,
/// "recoveryMode": Bool }`. Only `error` and `message` are read.
struct ServiceUnavailableBody: Decodable {
  var error: String?
  var message: String?

  static func decode(_ data: Data) -> ServiceUnavailableBody? {
    guard !data.isEmpty else { return nil }
    return try? JSONDecoder().decode(ServiceUnavailableBody.self, from: data)
  }
}
