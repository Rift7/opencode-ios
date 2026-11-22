import Foundation
import OpenCodeCore

/// A saved server: where it is, and how to authorize.
///
/// Manual entry builds one directly. Pairing decodes a `PairingLink` and redeems it for a token,
/// which becomes `password`; every later request for this server's origin carries it.
public struct OpenCodeServer: Sendable, Equatable, Codable {
  /// The address currently in use; every request goes here.
  public var url: String
  public var username: String
  public var password: String
  /// Other addresses the same server answers on (LAN, tailnet, tunnel), probed when connecting.
  public var alternateURLs: [String]
  /// The name the person gave this server on this phone; null shows `defaultName`.
  public var name: String?
  /// Sent with every request to this server's origins (a proxy such as Cloudflare Access may need
  /// them). Never sent to another origin.
  public var headers: [Header]
  /// The addresses the pairing code itself listed, which win over ones the server reports later.
  public var preferredURLs: [String]

  public struct Header: Sendable, Equatable, Codable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
      self.name = name
      self.value = value
    }

    /// An HTTP field name: one or more token characters (RFC 9110 §5.6.2).
    public var hasValidName: Bool {
      !name.isEmpty && name.allSatisfy { Self.tokenCharacters.contains($0) }
    }

    /// A field value cannot carry a line break, which would start another header. Scalars rather
    /// than characters: a CRLF is one grapheme cluster in Swift and must still be refused.
    public var hasValidValue: Bool {
      !value.unicodeScalars.contains { Self.newlines.contains($0.value) }
    }

    private static let tokenCharacters = Set(
      "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    )
    private static let newlines: Set<UInt32> = [0x0A, 0x0D, 0x0B, 0x0C, 0x85, 0x2028, 0x2029]
  }

  public init(
    url: String,
    username: String = "opencode",
    password: String = "",
    alternateURLs: [String] = [],
    name: String? = nil,
    headers: [Header] = [],
    preferredURLs: [String] = []
  ) {
    self.url = url
    self.username = username
    self.password = password
    self.alternateURLs = alternateURLs
    self.name = name
    self.headers = headers
    self.preferredURLs = preferredURLs
  }

  /// Stable across whichever LAN or tailnet address won the latest connection.
  public var persistenceID: String {
    ([username] + candidateURLs.sorted()).joined(separator: "|")
  }

  /// The same server under a changed address set or username still replaces its old entry.
  public func supersedes(_ saved: OpenCodeServer) -> Bool {
    saved.persistenceID == persistenceID || saved.url == url
  }

  /// Every address to try, primary first, deduplicated in listed order.
  public var candidateURLs: [String] {
    var seen = Set<String>()
    return ([url] + alternateURLs).filter { seen.insert($0).inserted }
  }

  /// The host and port in use, without a scheme.
  public var host: String {
    guard let origin = ServerOrigin(address: url) else { return url }
    return origin.port.map { "\(origin.host):\($0)" } ?? origin.host
  }

  public var isSecure: Bool {
    url.lowercased().hasPrefix("https")
  }

  /// Pairs with a V2 `opencode pair` link: the password is a signed session token (`<expiry>.<sig>`).
  public var usesPairingToken: Bool {
    password.wholeMatch(of: /[0-9]{10,}\.[A-Za-z0-9_-]{20,}/) != nil
  }

  /// What the app calls this server: the person's name, else a name derived from its address.
  public var displayName: String {
    let chosen = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return chosen.isEmpty ? defaultName : chosen
  }

  /// The machine's name when an address carries one (a tailnet or Bonjour label), else the address
  /// in use shortened the same way.
  public var defaultName: String {
    let named = candidateURLs.compactMap { ServerOrigin(address: $0)?.host.lowercased() }
      .first { $0.hasSuffix(".ts.net") || $0.hasSuffix(".local") }
    return Self.machineName(named ?? host)
  }

  /// Adds this server's custom headers, then its credentials. A header that cannot be sent is
  /// skipped rather than failing the request: one bad saved header must not lock the person out.
  public var wireHeaders: [String: String] {
    var result: [String: String] = [:]
    for header in headers where header.hasValidName && header.hasValidValue {
      result[header.name] = header.value
    }
    if let authorization = basicAuthorization {
      result["Authorization"] = authorization
    }
    return result
  }

  /// The `Authorization` header value, or nil when no password is set.
  public var basicAuthorization: String? {
    guard !password.isEmpty else { return nil }
    let text = "\(username):\(password)"
    return "Basic " + Data(text.utf8).base64EncodedString()
  }

  /// The same server under a changed address set.
  public func at(url: String) -> OpenCodeServer {
    var copy = self
    copy.url = url
    copy.alternateURLs = candidateURLs.filter { $0 != url }
    return copy
  }

  /// This server with `preferred`'s address order, when both list the same addresses.
  public func keepingAddressOrder(_ preferred: OpenCodeServer?) -> OpenCodeServer {
    guard let preferred, preferred.persistenceID == persistenceID else { return self }
    var copy = self
    copy.url = preferred.url
    copy.alternateURLs = preferred.alternateURLs
    return copy
  }

  /// A re-paired server keeps the name and headers its saved entry had: a code carries neither.
  public func keepingLocalSettings(saved: [OpenCodeServer]) -> OpenCodeServer {
    guard let old = saved.first(where: supersedes) else { return self }
    var copy = self
    copy.name = old.name ?? name
    if headers.isEmpty { copy.headers = old.headers }
    return copy
  }

  /// No saved entry is this server or shares one of its addresses: pairing it adds a computer.
  public func isNewComputer(saved: [OpenCodeServer]) -> Bool {
    let addresses = Set(candidateURLs)
    return !saved.contains { entry in
      supersedes(entry) || !addresses.isDisjoint(with: entry.candidateURLs)
    }
  }

  /// Whether `target` shares scheme, host and effective port with any of this server's addresses.
  public func matchesOrigin(_ target: URL) -> Bool {
    guard let candidate = HTTPOrigin(target) else { return false }
    return candidateURLs.contains { address in
      guard let url = URL(string: address) else { return false }
      return HTTPOrigin(url) == candidate
    }
  }

  /// `path` on this server, replacing any query or fragment in the saved address.
  ///
  /// Query pairs are encoded the way the audited transport encodes them: `/`, `:`, `?` stay literal
  /// and `[` `]` are escaped, so `location[directory]` travels as `location%5Bdirectory%5D`.
  public func endpoint(path: String, query: [(name: String, value: String)] = []) -> URL? {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let parsed = URLComponents(string: trimmed),
      let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = parsed.host, !host.isEmpty,
      var components = URLComponents(url: parsed.url ?? URL(string: trimmed)!, resolvingAgainstBaseURL: false)
    else { return nil }
    let encodedPath = Self.percentEncodePath(path.hasPrefix("/") ? path : "/" + path)
    components.percentEncodedPath = encodedPath
    components.percentEncodedQuery =
      query.isEmpty
      ? nil
      : query.map {
        "\(Self.percentEncodeQueryComponent($0.name))=\(Self.percentEncodeQueryComponent($0.value))"
      }.joined(separator: "&")
    return components.url
  }

  /// A request for `path` carrying this server's headers for this request's origin.
  public func request(
    path: String,
    query: [(name: String, value: String)] = [],
    method: String = "GET",
    body: Data? = nil,
    timeout: TimeInterval = 10,
    redirectPolicy: HTTPRedirectPolicy = .followSameOrigin
  ) -> HTTPRequest? {
    guard let url = endpoint(path: path, query: query) else { return nil }
    return HTTPRequest(
      url: url,
      method: method,
      headers: wireHeaders.filter { $0.key != "Authorization" },
      authorization: basicAuthorization,
      body: body,
      timeout: timeout,
      redirectPolicy: redirectPolicy
    )
  }

  // MARK: - Encoding

  /// Percent-encodes a URL path as Foundation's `urlPathAllowed` does, keeping `/`.
  static func percentEncodePath(_ text: String) -> String {
    let allowed = Set("!$&'()*+,-.:;=@_~/")
    return percentEncode(text, allowed: allowed)
  }

  /// Percent-encodes a query name or value, keeping what Foundation keeps in a query.
  static func percentEncodeQueryComponent(_ text: String) -> String {
    let allowed = Set("-._~!$'()*,;:@/?")
    return percentEncode(text, allowed: allowed)
  }

  private static func percentEncode(_ text: String, allowed: Set<Character>) -> String {
    var result = ""
    result.reserveCapacity(text.utf8.count)
    for byte in text.utf8 {
      let scalar = Character(UnicodeScalar(byte))
      if byte < 0x80, scalar.isLetter || scalar.isNumber || allowed.contains(scalar) {
        result.append(scalar)
      } else {
        result.append(String(format: "%%%02X", byte))
      }
    }
    return result
  }

  /// A host name's first label ("basebook" of basebook.tail1234.ts.net:4443), or the whole address
  /// for an IP literal.
  public static func machineName(_ host: String) -> String {
    let address = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host
    let labels = address.split(separator: ".").filter { !$0.isEmpty }
    if labels.count <= 1 || address.allSatisfy({ $0.isNumber || $0 == "." }) { return host }
    return String(labels[0])
  }

  /// "http://100.64.0.3:4096": scheme, host and port lowercased, with the scheme's default port.
  public static func origin(_ url: String) -> String? {
    ServerOrigin(address: url)?.dedupKey
  }
}
