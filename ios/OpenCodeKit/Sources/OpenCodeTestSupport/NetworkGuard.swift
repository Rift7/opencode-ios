import Foundation
import Synchronization

public enum NetworkGuardError: Error, Equatable, Sendable {
  /// A request was attempted against a host no test registered.
  case blocked
}

/// A `URLProtocol` that makes accidental live networking impossible in tests.
///
/// Every request through a session built by `makeSession()` is either answered from a registered
/// fixture or fails with `NetworkGuardError.blocked`. Nothing is forwarded to the network stack.
/// Fixtures can also redirect, stream a body in chunks, and record the request that produced them.
public final class NetworkGuard: URLProtocol {
  public struct Fixture: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data
    /// When set, the body is delivered in these pieces, then the load finishes. Models a
    /// fragmented stream.
    public var chunks: [Data]?
    /// When set, the response is a redirect to this absolute address. The body is delivered if the
    /// redirect is refused.
    public var redirect: URL?

    public init(
      statusCode: Int = 200,
      headers: [String: String] = [:],
      body: Data = Data(),
      chunks: [Data]? = nil,
      redirect: URL? = nil
    ) {
      self.statusCode = statusCode
      self.headers = headers
      self.body = body
      self.chunks = chunks
      self.redirect = redirect
    }
  }

  public struct RecordedRequest: Sendable, Equatable {
    public var host: String
    public var method: String
    /// Path and query, exactly as sent.
    public var path: String
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(host: String, method: String, path: String, headers: [String: String], body: Data) {
      self.host = host
      self.method = method
      self.path = path
      self.headers = headers
      self.body = body
    }
  }

  private struct State {
    var fixtures: [String: Fixture] = [:]
    var pathFixtures: [String: Fixture] = [:]
    var requestedHosts: [String] = []
    var recorded: [RecordedRequest] = []
  }

  private static let state = Mutex(State())

  public static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NetworkGuard.self]
    return URLSession(configuration: configuration)
  }

  /// Serves `fixture` for every request to `host`.
  public static func register(host: String, fixture: Fixture) {
    state.withLock { $0.fixtures[host] = fixture }
  }

  /// Serves `fixture` for requests whose path and query match exactly, before the host's fixture.
  public static func register(host: String, path: String, fixture: Fixture) {
    state.withLock { $0.pathFixtures["\(host)|\(path)"] = fixture }
  }

  public static func reset() {
    state.withLock { $0 = State() }
  }

  /// Hosts requested since the last `reset()`, in order.
  public static var requestedHosts: [String] {
    state.withLock { $0.requestedHosts }
  }

  /// Every request seen since the last `reset()`, with its method, path, headers and body.
  public static var recordedRequests: [RecordedRequest] {
    state.withLock { $0.recorded }
  }

  public static func fixture(for host: String) -> Fixture? {
    state.withLock { $0.fixtures[host] }
  }

  public override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  public override func startLoading() {
    let host = request.url?.host() ?? ""
    let recorded = RecordedRequest(
      host: host,
      method: request.httpMethod ?? "GET",
      path: request.url.map { pathWithQuery($0) } ?? "",
      headers: lowercasedHeaders(request.allHTTPHeaderFields ?? [:]),
      body: request.httpBody ?? bodyStreamData(request.httpBodyStream)
    )
    let fixture = Self.state.withLock { state -> Fixture? in
      state.requestedHosts.append(host)
      state.recorded.append(recorded)
      return state.pathFixtures["\(host)|\(recorded.path)"] ?? state.fixtures[host]
    }

    guard let fixture, let url = request.url else {
      client?.urlProtocol(self, didFailWithError: NetworkGuardError.blocked)
      return
    }

    let headers = fixture.headers.merging(["Content-Type": "application/json"]) { current, _ in current }
    let response = HTTPURLResponse(
      url: url,
      statusCode: fixture.statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )!

    if let redirect = fixture.redirect {
      var newRequest = URLRequest(url: redirect)
      newRequest.httpMethod = request.httpMethod
      newRequest.allHTTPHeaderFields = request.allHTTPHeaderFields
      client?.urlProtocol(self, wasRedirectedTo: newRequest, redirectResponse: response)
      return
    }

    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if let chunks = fixture.chunks {
      for chunk in chunks {
        client?.urlProtocol(self, didLoad: chunk)
      }
    } else {
      client?.urlProtocol(self, didLoad: fixture.body)
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  public override func stopLoading() {}

  private func pathWithQuery(_ url: URL) -> String {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.scheme = nil
    components?.host = nil
    components?.port = nil
    var text = components?.percentEncodedPath ?? url.path
    if let query = components?.percentEncodedQuery {
      text += "?" + query
    }
    return text
  }

  private func lowercasedHeaders(_ headers: [String: String]) -> [String: String] {
    var result: [String: String] = [:]
    for (name, value) in headers {
      result[name.lowercased()] = value
    }
    return result
  }

  /// `URLSession` turns a request body into a stream before the protocol sees it.
  private func bodyStreamData(_ stream: InputStream?) -> Data {
    guard let stream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let size = 4096
    var buffer = [UInt8](repeating: 0, count: size)
    while stream.hasBytesAvailable {
      let read = stream.read(&buffer, maxLength: size)
      if read <= 0 { break }
      data.append(buffer, count: read)
    }
    return data
  }
}
