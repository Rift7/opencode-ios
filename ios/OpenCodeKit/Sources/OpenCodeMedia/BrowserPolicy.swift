import Foundation
import OpenCodeServer

/// Where a link tapped in a reply or a page goes.
public enum BrowserLinkRoute: Equatable, Sendable {
  case file(String)
  case inAppBrowser(String)
  case system(String)
}

/// Which links the in-app browser takes: public `http(s)` pages only. Loopback, private, tailnet,
/// single-label and IP-literal hosts, embedded credentials and URLs carrying a token or signature
/// stay with the system, so a page context and server credentials never touch them.
public enum BrowserLinkPolicy {
  public static func route(
    url: String,
    inAppBrowser: Bool,
    allowsLoopback: Bool = false
  ) -> BrowserLinkRoute {
    if let reference = AgentFileLink.parse(url) { return .file(reference) }
    guard inAppBrowser, isPublicWebPage(url, allowsLoopback: allowsLoopback) else {
      return .system(url)
    }
    return .inAppBrowser(url)
  }

  public static func isPublicWebPage(_ url: String, allowsLoopback: Bool = false) -> Bool {
    guard !PairingLink.shouldHandleOpenURL(url) else { return false }
    guard let components = URLComponents(string: url) else { return false }
    let scheme = components.scheme?.lowercased()
    guard scheme == "http" || scheme == "https" else { return false }
    guard components.user == nil, components.password == nil else { return false }
    guard let rawHost = components.host?.lowercased() else { return false }
    let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
    guard !host.isEmpty else { return false }
    if allowsLoopback, isLoopback(host) { return true }
    if let port = components.port, port != 80, port != 443 { return false }
    if isIPLiteral(host) { return false }
    guard host.contains(".") else { return false }
    if privateSuffixes.contains(where: { host == $0.dropFirst() || host.hasSuffix($0) }) { return false }
    return !queryNames(components).contains(where: isCredential)
  }

  public static func isLoopback(_ host: String) -> Bool {
    ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
  }

  /// The Unicode host without `www.`; nil when the URL has none.
  public static func displayHost(_ url: String) -> String? {
    guard let host = URLComponents(string: url)?.host?.lowercased(), !host.isEmpty else { return nil }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  private static let privateSuffixes = [
    ".localhost", ".local", ".internal", ".intranet", ".lan", ".home", ".corp", ".home.arpa",
    ".test", ".invalid", ".ts.net", ".onion",
  ]

  private static func queryNames(_ components: URLComponents) -> [String] {
    (components.queryItems ?? []).map { $0.name.lowercased() }
  }

  private static func isIPLiteral(_ host: String) -> Bool {
    if host.contains(":") || host.hasPrefix("[") { return true }
    let labels = host.split(separator: ".").filter { !$0.isEmpty }
    return !labels.isEmpty && labels.allSatisfy { $0.allSatisfy(\.isNumber) }
  }

  private static func isCredential(_ name: String) -> Bool {
    let exact: Set<String> = [
      "key", "apikey", "api_key", "auth", "authorization", "code", "sig", "sid", "session",
      "sessionid", "jwt", "otp", "ticket", "pass", "pwd", "credential", "credentials",
      "x-amz-credential", "x-goog-credential",
    ]
    if exact.contains(name) { return true }
    return ["token", "signature", "secret", "password"].contains { name.contains($0) }
  }
}

/// What the page's own navigations may do. Only public pages load; a main-frame link the person
/// taps that leaves that set is handed to the system, and a script- or redirect-initiated one is
/// cancelled. A pairing link is never loaded by the browser.
public enum BrowserNavigationPolicy {
  public enum Decision: Equatable, Sendable {
    case allow
    case cancel
    case openInSystem(String)
    case pair(String)
  }

  public static func decide(
    url: String?,
    isMainFrame: Bool,
    isUserTap: Bool,
    allowsLoopback: Bool = false
  ) -> Decision {
    guard let url else { return .cancel }
    guard let scheme = scheme(of: url) else { return .cancel }
    if PairingLink.shouldHandleOpenURL(url) {
      return isMainFrame && isUserTap ? .pair(url) : .cancel
    }
    switch scheme {
    case "about":
      return !isMainFrame || url == "about:blank" || url == "about:srcdoc" ? .allow : .cancel
    case "data", "blob":
      return isMainFrame ? .cancel : .allow
    case "http", "https":
      if BrowserLinkPolicy.isPublicWebPage(url, allowsLoopback: allowsLoopback) { return .allow }
      return isMainFrame && isUserTap ? .openInSystem(url) : .cancel
    default:
      return isMainFrame && isUserTap ? .openInSystem(url) : .cancel
    }
  }

  public static func handsToSystem(canShow: Bool, disposition: String?) -> Bool {
    if !canShow { return true }
    return disposition?.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") == true
  }

  private static func scheme(of url: String) -> String? {
    guard let colon = url.firstIndex(of: ":"), colon != url.startIndex else { return nil }
    let scheme = url[url.startIndex..<colon]
    guard let first = scheme.first, first.isLetter else { return nil }
    guard scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else { return nil }
    return scheme.lowercased()
  }
}

/// A `opencode-file://open?path=…&line=…` link, or a Markdown destination naming a path. P10 routes
/// it to the file viewer; the model lives with the transcript's file references.
public enum AgentFileLink {
  public static func parse(_ url: String) -> String? {
    guard let components = URLComponents(string: url), components.scheme == "opencode-file" else {
      return nil
    }
    return components.queryItems?.first(where: { $0.name == "path" })?.value
  }
}
