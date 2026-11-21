import Foundation

/// How the phone reaches a server, from the address it is using. Ordering is by how likely the
/// address is to keep working away from the server's own network.
public enum ConnectionRoute: String, Sendable, Equatable, CaseIterable {
  case internet = "Internet"
  case tailscale = "Tailscale"
  case localNetwork = "Local Network"
  case loopback = "Loopback"

  /// Straight to the computer (a LAN or tailnet address), not through a relay or the internet.
  public var isDirect: Bool { self == .tailscale || self == .localNetwork }
}

/// A URL host classified once: an IPv4 or IPv6 literal (parsed, never guessed from spelling, so
/// `fd.example.com` is a name) or a name.
public struct HostAddress: Sendable, Equatable {
  public enum Family: Sendable, Equatable {
    case ipv4
    case ipv6
    case name
  }

  /// Lowercased, without IPv6 brackets or zone (`fe80::1%en0` → `fe80::1`).
  public let host: String
  public let family: Family
  /// Four or sixteen bytes for a literal; empty for a name.
  public let bytes: [UInt8]
  /// An IPv6 literal scoped to an interface (`%en0`).
  public let hasZone: Bool

  public var isIP: Bool { family != .name }

  public var isLoopback: Bool {
    switch family {
    case .ipv4:
      return bytes.first == 127
    case .ipv6:
      return bytes.count == 16 && bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
    case .name:
      return host == "localhost"
    }
  }

  public var route: ConnectionRoute {
    if isLoopback { return .loopback }
    switch family {
    case .ipv4:
      let b = bytes
      guard b.count == 4 else { return .internet }
      if b[0] == 100 && (64...127).contains(b[1]) { return .tailscale }
      let isPrivate =
        b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
        || (b[0] == 169 && b[1] == 254)
      return isPrivate ? .localNetwork : .internet
    case .ipv6:
      let b = bytes
      guard b.count == 16 else { return .internet }
      if b.prefix(6).elementsEqual([0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]) { return .tailscale }
      let uniqueLocal = (b[0] & 0xFE) == 0xFC
      let linkLocal = b[0] == 0xFE && (b[1] & 0xC0) == 0x80
      return uniqueLocal || linkLocal ? .localNetwork : .internet
    case .name:
      if host.hasSuffix(".ts.net") { return .tailscale }
      if host.hasSuffix(".local") { return .localNetwork }
      return .internet
    }
  }

  public init(host: String, family: Family, bytes: [UInt8] = [], hasZone: Bool = false) {
    self.host = host
    self.family = family
    self.bytes = bytes
    self.hasZone = hasZone
  }

  public static func ofURL(_ url: URL) -> HostAddress? {
    guard let host = url.host() else { return nil }
    return of(host)
  }

  /// Parses a host as it appears in a URL or an authority: brackets and a zone are accepted.
  public static func of(_ raw: String) -> HostAddress? {
    var host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    guard !host.isEmpty else { return nil }
    var zoned = false
    if host.contains(":") {
      if let percent = host.firstIndex(of: "%") {
        host = String(host[..<percent])
        zoned = true
      }
    }
    if let v4 = parseIPv4(host) {
      return HostAddress(host: host, family: .ipv4, bytes: v4)
    }
    if let v6 = parseIPv6(host) {
      // An IPv4-mapped address (::ffff:0:0/96) is its IPv4 address.
      if v6.prefix(10).allSatisfy({ $0 == 0 }) && v6[10] == 0xFF && v6[11] == 0xFF {
        return HostAddress(host: host, family: .ipv4, bytes: Array(v6[12..<16]))
      }
      return HostAddress(host: host, family: .ipv6, bytes: v6, hasZone: zoned)
    }
    return HostAddress(host: host, family: .name)
  }

  /// `inet_pton(AF_INET)`: four decimal octets, no leading zeros.
  public static func parseIPv4(_ text: String) -> [UInt8]? {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var bytes: [UInt8] = []
    for part in parts {
      guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber) else { return nil }
      if part.count > 1 && part.first == "0" { return nil }
      guard let value = UInt8(part) else { return nil }
      bytes.append(value)
    }
    return bytes
  }

  /// `inet_pton(AF_INET6)`, including `::` compression and a trailing dotted IPv4.
  public static func parseIPv6(_ text: String) -> [UInt8]? {
    guard !text.isEmpty, text.contains(":") else { return nil }
    guard let doubleColon = text.range(of: "::") else {
      return groups(text).flatMap { $0.count == 8 ? wordsToBytes($0) : nil }
    }
    if text.range(of: "::", range: doubleColon.upperBound..<text.endIndex) != nil { return nil }
    let head = groups(String(text[..<doubleColon.lowerBound])) ?? []
    let tailText = String(text[doubleColon.upperBound...])
    let tail = groups(tailText) ?? []
    let missing = 8 - head.count - tail.count
    guard missing >= 1 else { return nil }
    return wordsToBytes(head + Array(repeating: 0, count: missing) + tail)
  }

  private static func groups(_ part: String) -> [Int]? {
    if part.isEmpty { return [] }
    var result: [Int] = []
    let pieces = part.split(separator: ":", omittingEmptySubsequences: false)
    for (index, piece) in pieces.enumerated() {
      if index == pieces.count - 1 && piece.contains(".") {
        guard let v4 = parseIPv4(String(piece)), v4.count == 4 else { return nil }
        result.append((Int(v4[0]) << 8) | Int(v4[1]))
        result.append((Int(v4[2]) << 8) | Int(v4[3]))
        continue
      }
      guard !piece.isEmpty, piece.count <= 4, piece.allSatisfy(\.isHexDigit),
        let value = Int(piece, radix: 16)
      else { return nil }
      result.append(value)
    }
    return result
  }

  private static func wordsToBytes(_ words: [Int]) -> [UInt8] {
    words.flatMap { [UInt8(($0 >> 8) & 0xFF), UInt8($0 & 0xFF)] }
  }
}

/// The cleartext policy carried from the audited Android transport: plain HTTP only to private
/// networks, overlay networks and local names. Public hosts use HTTPS.
///
/// ATS is configured separately (`project.yml`): `NSAllowsLocalNetworking` covers IP literals and
/// `.local`, and the overlay domains are named exception domains. This policy is the second gate
/// and applies regardless of what ATS would allow.
public enum TransportSecurity {
  /// Overlay and private-use names ATS's local networking exception misses.
  public static let insecureExceptionDomains = [
    "ts.net", "netbird.cloud", "netbird.selfhosted", "home.arpa", "internal",
  ]

  /// Whether a plain-HTTP load to `host` is allowed.
  public static func allowsInsecureHTTP(host: String) -> Bool {
    guard let address = HostAddress.of(host) else { return false }
    switch address.family {
    case .ipv4:
      let b = address.bytes
      guard b.count == 4 else { return false }
      if address.isLoopback { return true }
      if b[0] == 10 { return true }
      if b[0] == 172 && (16...31).contains(b[1]) { return true }
      if b[0] == 192 && b[1] == 168 { return true }
      if b[0] == 169 && b[1] == 254 { return true }
      // CGNAT 100.64.0.0/10: Tailscale, NetBird, WARP and friends.
      if b[0] == 100 && (64...127).contains(b[1]) { return true }
      return false
    case .ipv6:
      let b = address.bytes
      guard b.count == 16 else { return false }
      if address.isLoopback { return true }
      if (b[0] & 0xFE) == 0xFC { return true }
      if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return true }
      return false
    case .name:
      let name = address.host.hasSuffix(".") ? String(address.host.dropLast()) : address.host
      if !name.contains(".") || name.hasSuffix(".local") { return true }
      return insecureExceptionDomains.contains { name == $0 || name.hasSuffix(".\($0)") }
    }
  }

  public static func allowsInsecureHTTP(url: URL) -> Bool {
    guard url.scheme?.lowercased() == "http", let host = url.host() else { return true }
    return allowsInsecureHTTP(host: host)
  }
}
