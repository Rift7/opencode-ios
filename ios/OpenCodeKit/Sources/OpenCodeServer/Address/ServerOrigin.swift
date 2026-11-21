import Foundation
import OpenCodeCore

/// A server's base address normalized to its origin: HTTP(S), a host, no credentials, query,
/// fragment or path. Pairing payloads, manual entry and saved servers all pass through here, so the
/// same rules decide what the app will ever connect to.
public struct ServerOrigin: Sendable, Equatable, Hashable {
  /// Scheme lowercased, authority as written (IPv6 brackets kept, no trailing empty port).
  public let normalized: String
  public let scheme: String
  public let host: String
  public let port: Int?
  public let url: URL

  /// Why an address cannot be a server's base URL.
  public enum Problem: Error, Equatable, Sendable {
    case notAWebAddress
    case badScheme
    case noHost
    case credentials
    case query
    case port
    case path
  }

  private init(normalized: String, scheme: String, host: String, port: Int?, url: URL) {
    self.normalized = normalized
    self.scheme = scheme
    self.host = host
    self.port = port
    self.url = url
  }

  public init?(address: String) {
    guard case .success(let origin) = Self.parse(address) else { return nil }
    self = origin
  }

  /// The address with no trailing slash: what gets saved and compared.
  public var address: String { normalized }

  /// Two spellings of one address match: scheme, host and effective port.
  public var dedupKey: String {
    let effectivePort = port ?? (scheme == "https" ? 443 : 80)
    return "\(scheme)://\(host.lowercased()):\(effectivePort)"
  }

  public var isLoopback: Bool {
    HostAddress.of(host)?.isLoopback ?? false
  }

  public var route: ConnectionRoute {
    HostAddress.of(host)?.route ?? .internet
  }

  /// A validated origin, or the reason it was rejected.
  public static func parse(_ address: String) -> Result<ServerOrigin, Problem> {
    let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: trimmed), let rawScheme = components.scheme else {
      return .failure(.notAWebAddress)
    }
    let scheme = rawScheme.lowercased()
    guard scheme == "http" || scheme == "https" else { return .failure(.badScheme) }
    guard let host = components.host, !host.isEmpty else { return .failure(.noHost) }
    guard components.user == nil, components.password == nil else { return .failure(.credentials) }
    guard components.query == nil, components.fragment == nil else { return .failure(.query) }
    guard components.path.isEmpty || components.path == "/" else { return .failure(.path) }
    if let port = components.port, !(1...65535).contains(port) { return .failure(.port) }

    let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    let normalized = components.port.map { "\(scheme)://\(authority):\($0)" } ?? "\(scheme)://\(authority)"
    guard let url = URL(string: normalized) else { return .failure(.notAWebAddress) }
    return .success(
      ServerOrigin(normalized: normalized, scheme: scheme, host: host, port: components.port, url: url)
    )
  }

  /// Deduplicates addresses by scheme, host and effective port, keeping the first spelling.
  public static func deduplicated(_ addresses: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for address in addresses {
      guard let origin = ServerOrigin(address: address) else { continue }
      guard seen.insert(origin.dedupKey).inserted else { continue }
      result.append(origin.address)
    }
    return result
  }
}
