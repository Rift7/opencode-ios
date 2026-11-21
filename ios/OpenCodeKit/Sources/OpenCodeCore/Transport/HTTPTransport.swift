import ComposableArchitecture
import Foundation

public enum TransportError: Error, Equatable, Sendable {
  /// A test tried to reach the network through a dependency that was never given a fixture.
  case blocked
  /// A plain-HTTP request to a host the audited policy does not classify as local or overlay.
  case insecureHTTP
  /// A redirect left the request's origin while credentials are attached.
  case crossOriginRedirect
  /// The request could not be expressed as an HTTP request.
  case invalidRequest
  /// A stream was requested from a server that does not answer with one.
  case notAStream
}

/// How a request treats redirects. Credentials are bound to the origin a request was built for, so
/// following one to another host would hand a Basic header (or a proxy's token) to a stranger.
public enum HTTPRedirectPolicy: Sendable, Equatable {
  /// Follow a redirect only when scheme, host and effective port stay the same.
  case followSameOrigin
  /// Do not follow; the 3xx is delivered as the response.
  case reject
}

/// What a redirect handler does with one hop, decided without a session so it can be tested.
public enum HTTPRedirectDecision: Sendable, Equatable {
  /// Follow to this request, with the original headers and credentials re-applied.
  case follow(URLRequest)
  /// The policy rejects redirects; the 3xx is the answer.
  case refuse
  /// The target left the request's origin, so its headers and credentials must not travel there.
  case refuseCrossOrigin
}

/// The one rule for a redirect hop. Credentials are bound to the origin the request was built for.
public struct HTTPRedirectRule: Sendable, Equatable {
  public var origin: HTTPOrigin?
  public var policy: HTTPRedirectPolicy
  public var headers: [String: String]

  public init(origin: HTTPOrigin?, policy: HTTPRedirectPolicy, headers: [String: String]) {
    self.origin = origin
    self.policy = policy
    self.headers = headers
  }

  public init(request: HTTPRequest) {
    self.init(origin: HTTPOrigin(request.url), policy: request.redirectPolicy, headers: request.wireHeaders)
  }

  public func decide(_ target: URLRequest) -> HTTPRedirectDecision {
    guard policy == .followSameOrigin else { return .refuse }
    guard let origin, let url = target.url, let targetOrigin = HTTPOrigin(url), targetOrigin == origin else {
      return .refuseCrossOrigin
    }
    var allowed = target
    for (name, value) in headers {
      allowed.setValue(value, forHTTPHeaderField: name)
    }
    return .follow(allowed)
  }
}

/// One HTTP request. Headers and the authorization value belong to `url`'s origin and are only sent
/// there; the transport enforces that through redirects.
public struct HTTPRequest: Sendable, Equatable {
  public var url: URL
  public var method: String
  /// Sent with the request. A redirect that leaves the origin is refused, so these never travel
  /// to an unrelated destination.
  public var headers: [String: String]
  /// The full `Authorization` value (`Basic …`), when the server has a password.
  public var authorization: String?
  public var body: Data?
  public var timeout: TimeInterval
  public var redirectPolicy: HTTPRedirectPolicy

  public init(
    url: URL,
    method: String = "GET",
    headers: [String: String] = [:],
    authorization: String? = nil,
    body: Data? = nil,
    timeout: TimeInterval = 10,
    redirectPolicy: HTTPRedirectPolicy = .followSameOrigin
  ) {
    self.url = url
    self.method = method
    self.headers = headers
    self.authorization = authorization
    self.body = body
    self.timeout = timeout
    self.redirectPolicy = redirectPolicy
  }

  /// Every header the wire request carries. Used by tests and by the redirect handler.
  public var wireHeaders: [String: String] {
    var all = headers
    if let authorization {
      all["Authorization"] = authorization
    }
    return all
  }
}

public struct HTTPResponse: Sendable, Equatable {
  public var status: Int
  /// Header names lowercased.
  public var headers: [String: String]
  public var body: Data
  /// The URL that produced the response; differs from the request only after a same-origin redirect.
  public var finalURL: URL

  public init(status: Int, headers: [String: String], body: Data, finalURL: URL) {
    self.status = status
    self.headers = headers
    self.body = body
    self.finalURL = finalURL
  }

  public func header(_ name: String) -> String? {
    headers[name.lowercased()]
  }
}

/// An open response: status and headers arrived, and the body is delivered incrementally.
public struct HTTPStream: Sendable {
  public var status: Int
  public var headers: [String: String]
  public var finalURL: URL
  /// Body chunks in arrival order. The producer never buffers more than the transport's bound; an
  /// overflow ends the stream with an error instead of dropping bytes.
  public var chunks: AsyncThrowingStream<Data, any Error>

  public init(
    status: Int,
    headers: [String: String],
    finalURL: URL,
    chunks: AsyncThrowingStream<Data, any Error>
  ) {
    self.status = status
    self.headers = headers
    self.finalURL = finalURL
    self.chunks = chunks
  }

  public func header(_ name: String) -> String? {
    headers[name.lowercased()]
  }
}

/// The single seam through which the app may perform HTTP work. Features resolve this dependency;
/// they never create a `URLSession` themselves, so a test that forgets an override still cannot
/// reach the network.
public struct HTTPTransport: Sendable {
  public var send: @Sendable (HTTPRequest) async throws -> HTTPResponse
  public var open: @Sendable (HTTPRequest) async throws -> HTTPStream

  public init(
    send: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse,
    open: @escaping @Sendable (HTTPRequest) async throws -> HTTPStream
  ) {
    self.send = send
    self.open = open
  }
}

extension HTTPTransport: DependencyKey {
  /// The live value is the only place a `URLSession` is created for features.
  public static var liveValue: HTTPTransport {
    let live = URLSessionTransport()
    return HTTPTransport(send: live.send, open: live.open)
  }

  public static let testValue = HTTPTransport(
    send: { _ in throw TransportError.blocked },
    open: { _ in throw TransportError.blocked }
  )
}

extension DependencyValues {
  public var httpTransport: HTTPTransport {
    get { self[HTTPTransport.self] }
    set { self[HTTPTransport.self] = newValue }
  }
}
