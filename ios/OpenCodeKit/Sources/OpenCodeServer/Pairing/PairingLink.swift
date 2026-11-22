import Foundation
import OpenCodeCore

/// Why a pairing link's address was rejected. The copy that names the reason belongs to the UI;
/// this stays a typed value so a test never matches on a sentence.
public enum PairingAddressProblem: Error, Equatable, Sendable {
  case notAWebAddress
  case badScheme
  case noHost
  case credentials
  case query
  case port
  case path

  init(_ problem: ServerOrigin.Problem) {
    switch problem {
    case .notAWebAddress: self = .notAWebAddress
    case .badScheme: self = .badScheme
    case .noHost: self = .noHost
    case .credentials: self = .credentials
    case .query: self = .query
    case .port: self = .port
    case .path: self = .path
    }
  }
}

/// A one-time `opencode pair` link: JSON `{"code","urls","name"?}`, the `https://opencode.ai/pair#…`
/// page, an `opencode(-ios)://pair?code=…&url=…` deep link, or one `…/auth/connect/<code>` link.
///
/// Decoding never contacts anything: a single-use code must not be spent by a paste, a share preview
/// or a link unfurl. Redemption is a separate client call, deliberately not reachable from here.
public struct PairingLink: Sendable, Equatable {
  /// Scheme, host and port only; the first listed address.
  public let origin: String
  public let code: String
  /// The other addresses the payload listed, in listed order.
  public let alternateOrigins: [String]
  /// The name the link suggests for the server, such as "Anomaly Box".
  public let name: String?

  public init(origin: String, code: String, alternateOrigins: [String] = [], name: String? = nil) {
    self.origin = origin
    self.code = code
    self.alternateOrigins = alternateOrigins
    self.name = name
  }

  /// Every address listed, deduplicated by origin, first spelling kept.
  public var candidateOrigins: [String] {
    ServerOrigin.deduplicated([origin] + alternateOrigins)
  }

  /// The addresses redemption will contact: loopback is omitted whenever a non-loopback address is
  /// listed, because a phone cannot reach the computer's own loopback.
  public var redeemOrigins: [String] {
    let reachable = candidateOrigins.filter { ServerOrigin(address: $0)?.isLoopback != true }
    return reachable.isEmpty ? candidateOrigins : reachable
  }

  /// This link restricted to `redeemOrigins`, so a confirmation screen and redemption agree.
  public var normalizedForRedemption: PairingLink {
    let origins = redeemOrigins
    guard let first = origins.first else { return self }
    return PairingLink(origin: first, code: code, alternateOrigins: Array(origins.dropFirst()), name: name)
  }

  /// No listed address is reachable from another device.
  public var isLoopback: Bool {
    let origins = candidateOrigins.compactMap { ServerOrigin(address: $0) }
    return !origins.isEmpty && origins.allSatisfy(\.isLoopback)
  }

  /// The unauthenticated descriptor redemption starts from.
  public var server: OpenCodeServer? {
    let origins = redeemOrigins
    guard let first = origins.first else { return nil }
    return OpenCodeServer(
      url: first,
      username: "opencode",
      password: "",
      alternateURLs: Array(origins.dropFirst()),
      name: name
    )
  }

  /// A custom-scheme deep link that opens the app without a web preview fetching the code.
  public var deepLinkURL: String {
    var items = [("code", code)] + candidateOrigins.map { ("url", $0) }
    if let name { items.append(("name", name)) }
    let query = items.map {
      "\(OpenCodeServer.percentEncodeQueryComponent($0.0))=\(OpenCodeServer.percentEncodeQueryComponent($0.1))"
    }.joined(separator: "&")
    return "opencode-ios://pair?" + query
  }

  /// Every saved server entry pairing this link would replace.
  public func replacedServers(saved: [OpenCodeServer]) -> [OpenCodeServer] {
    guard let candidate = server else { return [] }
    let origins = redeemOrigins
    var seen = Set<String>()
    return saved.filter { entry in
      let matches =
        candidate.supersedes(entry)
        || origins.contains { origin in
          entry.url == origin || entry.candidateURLs.contains(origin)
            || entry.matchesAnyOrigin(origins)
        }
      return matches && seen.insert(entry.persistenceID).inserted
    }
  }

  // MARK: - Decoding

  public enum DecodeFailure: Error, Equatable, Sendable {
    /// No form of pairing link was recognized.
    case unrecognized
    /// A recognized payload whose code or addresses are invalid.
    case invalidPayload(reason: PayloadProblem)
  }

  public enum PayloadProblem: Error, Equatable, Sendable {
    case missingCode
    case invalidCode
    case missingAddresses
    case unusableAddress(address: String, problem: PairingAddressProblem)
  }

  /// Decodes every supported form. `nil` means the text is not a pairing link.
  public static func decode(_ text: String) -> PairingLink? {
    try? decodeThrowing(text).get()
  }

  /// Decodes with the reason a pairing-shaped payload was rejected, for the error message only.
  public static func decodeThrowing(_ text: String) -> Result<PairingLink, DecodeFailure> {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("{") {
      return payloadLink(from: decodePayload(trimmed))
    }
    if let payload = decodeDeepLink(trimmed) {
      return payloadLink(from: payload)
    }
    if let payload = decodePairPage(trimmed) {
      return payloadLink(from: payload)
    }
    if let link = decodeConnectLink(trimmed) {
      return .success(link)
    }
    return .failure(.unrecognized)
  }

  /// The first address that keeps an otherwise well-formed code from decoding, for the error only.
  public static func unusableAddress(in text: String) -> (address: String, problem: PairingAddressProblem)? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let payload: RawPayload?
    if trimmed.hasPrefix("{") {
      payload = decodePayload(trimmed)
    } else if let deepLink = decodeDeepLink(trimmed) {
      payload = deepLink
    } else if let page = decodePairPage(trimmed) {
      payload = page
    } else {
      payload = nil
    }
    guard let payload else { return nil }
    for address in payload.urls {
      if case .failure(let problem) = ServerOrigin.parse(address) {
        return (shownAddress(address), PairingAddressProblem(problem))
      }
    }
    return nil
  }

  /// An address as an error may show it: no user name, password, query or fragment, at most 80
  /// characters.
  static func shownAddress(_ address: String) -> String {
    var shown = address.trimmingCharacters(in: .whitespacesAndNewlines)
    if let end = shown.firstIndex(where: { $0 == "?" || $0 == "#" }) {
      shown = String(shown[..<end])
    }
    if let range = shown.range(of: #"://[^/]*@"#, options: .regularExpression) {
      shown = shown.replacingCharacters(in: range, with: "://")
    }
    if shown.count > 80 {
      shown = String(shown.prefix(79)) + "…"
    }
    return shown
  }

  /// The pairing link in text as people copy it: wrapped by a terminal, inside a sentence, or with
  /// punctuation around it. Every link with the first one's code becomes one link with all their
  /// addresses.
  public static func decodeCopied(_ text: String) -> PairingLink? {
    if let link = decode(text) { return link }
    let unwrapped = text.replacingOccurrences(
      of: #"[ \t]*\r?\n[ \t]*(?![ \t]*\r?\n|(?i:https?|opencode(?:-ios)?)://)"#,
      with: "",
      options: .regularExpression
    )
    let links = copiedLinks(in: unwrapped).isEmpty ? copiedLinks(in: text) : copiedLinks(in: unwrapped)
    guard let first = links.first else { return nil }
    let origins = ServerOrigin.deduplicated(
      links.filter { $0.code == first.code }.flatMap(\.candidateOrigins)
    )
    guard let origin = origins.first else { return nil }
    return PairingLink(origin: origin, code: first.code, alternateOrigins: Array(origins.dropFirst()))
  }

  private static func copiedLinks(in text: String) -> [PairingLink] {
    let pattern = #"(?i)(?:https?|opencode(?:-ios)?)://[^\s<>"'`()\[\]{}]+"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return expression.matches(in: text, range: range).compactMap { match in
      guard let matchRange = Range(match.range, in: text) else { return nil }
      let raw = String(text[matchRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
      return decode(raw)
    }
  }

  /// Whether the text is `https://opencode.ai/pair`, even with a malformed fragment.
  public static func isPairPage(_ text: String) -> Bool {
    guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      components.scheme?.lowercased() == "https",
      components.host?.lowercased() == "opencode.ai"
    else { return false }
    return components.path == "/pair" || components.path == "/pair/"
  }

  /// Whether the text uses the app's pairing deep-link scheme and host, even when malformed.
  public static func isPairingScheme(_ text: String) -> Bool {
    guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      let scheme = components.scheme?.lowercased(), scheme == "opencode" || scheme == "opencode-ios",
      let host = components.host?.lowercased()
    else { return false }
    return host == "pair" || host == "connect"
  }

  /// Whether the text is an HTTP(S) URL targeting the reserved `/auth/connect` pairing route.
  public static func isPairingHTTPPath(_ text: String) -> Bool {
    guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = components.host, !host.isEmpty
    else { return false }
    let segments = components.path.split(separator: "/").map(String.init)
    return segments.count >= 2 && segments[0] == "auth" && segments[1] == "connect"
  }

  public static func isPairingEndpoint(_ text: String) -> Bool {
    isPairingScheme(text) || isPairingHTTPPath(text) || isPairPage(text)
  }

  /// Whether an opened URL is something this app handles as pairing.
  public static func shouldHandleOpenURL(_ url: String) -> Bool {
    decode(url) != nil || isPairingEndpoint(url)
  }

  /// The URL to copy or share: a valid pairing link becomes its non-fetching deep link, so no
  /// preview can spend the code; a malformed pairing link has none; anything else is unchanged.
  public static func shareableURL(_ url: String) -> String? {
    guard shouldHandleOpenURL(url) else { return url }
    return decode(url)?.deepLinkURL
  }

  /// Base64url, as the server mints them.
  public static func isValidCode(_ code: String) -> Bool {
    !code.isEmpty && code.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
  }

  // MARK: - Forms

  struct RawPayload {
    var code: String
    var urls: [String]
    var name: String?
  }

  private static func payloadLink(from payload: RawPayload?) -> Result<PairingLink, DecodeFailure> {
    guard let payload else { return .failure(.unrecognized) }
    guard isValidCode(payload.code) else {
      return .failure(.invalidPayload(reason: payload.code.isEmpty ? .missingCode : .invalidCode))
    }
    guard !payload.urls.isEmpty else {
      return .failure(.invalidPayload(reason: .missingAddresses))
    }
    var origins: [String] = []
    for address in payload.urls {
      switch ServerOrigin.parse(address) {
      case .success(let origin):
        origins.append(origin.address)
      case .failure(let problem):
        return .failure(
          .invalidPayload(
            reason: .unusableAddress(address: shownAddress(address), problem: PairingAddressProblem(problem))
          )
        )
      }
    }
    let deduplicated = ServerOrigin.deduplicated(origins)
    guard let first = deduplicated.first else {
      return .failure(.invalidPayload(reason: .missingAddresses))
    }
    let name = payload.name?.trimmingCharacters(in: .whitespacesAndNewlines)
    return .success(
      PairingLink(
        origin: first,
        code: payload.code,
        alternateOrigins: Array(deduplicated.dropFirst()),
        name: (name?.isEmpty ?? true) ? nil : name
      )
    )
  }

  private struct JSONPayload: Decodable {
    var code: String
    var urls: [String]
    var name: String?
  }

  private static func decodePayload(_ text: String) -> RawPayload? {
    guard let data = text.data(using: .utf8),
      let payload = try? JSONDecoder().decode(JSONPayload.self, from: data)
    else { return nil }
    return RawPayload(code: payload.code, urls: payload.urls, name: payload.name)
  }

  private static func decodeDeepLink(_ text: String) -> RawPayload? {
    guard isPairingScheme(text),
      let components = URLComponents(string: text),
      components.user == nil, components.password == nil,
      components.fragment == nil
    else { return nil }
    guard let queryItems = components.queryItems, !queryItems.isEmpty else { return nil }

    var pathCode: String?
    if !components.path.isEmpty && components.path != "/" {
      let parts = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
      guard parts.count == 2, parts[0].isEmpty, !parts[1].isEmpty else { return nil }
      pathCode = parts[1]
    }

    var queryCode: String?
    var urls: [String] = []
    var linkName: String?
    for item in queryItems {
      let value = item.value
      switch item.name.lowercased() {
      case "code":
        guard queryCode == nil, let value, !value.isEmpty else { return nil }
        queryCode = value
      case "url":
        guard let value, !value.isEmpty else { return nil }
        urls.append(value)
      case "urls":
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
          guard let data = trimmed.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String].self, from: data),
            !decoded.isEmpty
          else { return nil }
          urls.append(contentsOf: decoded)
        } else {
          urls.append(trimmed)
        }
      case "name":
        guard linkName == nil else { return nil }
        linkName = value ?? ""
      default:
        // Credential-bearing (username, password, token) and unknown parameters are refused.
        return nil
      }
    }
    if let pathCode, let queryCode, pathCode != queryCode { return nil }
    guard let code = queryCode ?? pathCode, isValidCode(code) else { return nil }
    return RawPayload(code: code, urls: urls, name: linkName)
  }

  /// `https://opencode.ai/pair#<payload>`: base64url JSON in the fragment.
  private static func decodePairPage(_ text: String) -> RawPayload? {
    guard isPairPage(text),
      let components = URLComponents(string: text),
      components.user == nil, components.password == nil,
      components.port == nil, components.query == nil
    else { return nil }
    guard let fragment = components.fragment, !fragment.isEmpty,
      let json = base64URLDecoded(fragment)
    else { return nil }
    return decodePayload(json)
  }

  private static func base64URLDecoded(_ text: String) -> String? {
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=")
    guard text.allSatisfy(allowed.contains) else { return nil }
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 = base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// One `scheme://authority/auth/connect/<code>` link.
  private static func decodeConnectLink(_ text: String) -> PairingLink? {
    guard let components = URLComponents(string: text),
      let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil
    else { return nil }
    let parts = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 4, parts[0].isEmpty, parts[1] == "auth", parts[2] == "connect",
      isValidCode(parts[3])
    else { return nil }
    let port = components.port.map { ":\($0)" } ?? ""
    let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    guard let origin = ServerOrigin(address: "\(scheme)://\(authority)\(port)") else { return nil }
    return PairingLink(origin: origin.address, code: parts[3])
  }
}

extension OpenCodeServer {
  func matchesAnyOrigin(_ origins: [String]) -> Bool {
    guard let selfOrigin = ServerOrigin(address: url) else { return false }
    return origins.contains { ServerOrigin(address: $0)?.dedupKey == selfOrigin.dedupKey }
  }
}
