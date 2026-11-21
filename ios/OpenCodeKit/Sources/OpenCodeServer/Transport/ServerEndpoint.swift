import Foundation

/// A saved server address, validated the way the pairing payload requires: an `http` or `https`
/// URL with a host, no credentials, query or fragment, and an empty or `/` path.
public struct ServerEndpoint: Sendable, Equatable {
  public let url: URL

  public init?(address: String) {
    guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return nil
    }
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      return nil
    }
    guard let host = url.host(), !host.isEmpty else { return nil }
    guard url.user == nil, url.password == nil else { return nil }
    guard url.query == nil, url.fragment == nil else { return nil }
    guard url.path.isEmpty || url.path == "/" else { return nil }
    self.url = url
  }

  /// Builds an endpoint URL, replacing any path or query the saved address carried.
  public func url(path: String, query: [String: String] = [:]) -> URL? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.path = path.hasPrefix("/") ? path : "/" + path
    if query.isEmpty {
      components.queryItems = nil
    } else {
      components.queryItems = query
        .sorted { $0.key < $1.key }
        .map { URLQueryItem(name: $0.key, value: $0.value) }
    }
    return components.url
  }

  /// The only directory-scoping query name the server accepts. A bare `directory` is ignored.
  public static func locationDirectory(_ directory: String) -> (String, String) {
    ("location[directory]", directory)
  }

  /// A display value that never includes credentials.
  public var displayAddress: String {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.user = nil
    components?.password = nil
    return components?.string ?? url.absoluteString
  }
}
