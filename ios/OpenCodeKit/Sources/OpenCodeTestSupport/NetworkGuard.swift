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
public final class NetworkGuard: URLProtocol {
  private struct State {
    var fixtures: [String: Fixture] = [:]
    var requestedHosts: [String] = []
  }

  public struct Fixture: Sendable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int = 200, body: Data = Data()) {
      self.statusCode = statusCode
      self.body = body
    }
  }

  private static let state = Mutex(State())

  public static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NetworkGuard.self]
    return URLSession(configuration: configuration)
  }

  /// Serves `body` for every request to `host`.
  public static func register(host: String, fixture: Fixture) {
    state.withLock { $0.fixtures[host] = fixture }
  }

  public static func reset() {
    state.withLock { $0 = State() }
  }

  /// Hosts requested since the last `reset()`, in order. Assert on this to prove a test did not
  /// try to reach anything unexpected.
  public static var requestedHosts: [String] {
    state.withLock { $0.requestedHosts }
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
    Self.state.withLock { $0.requestedHosts.append(host) }

    guard let fixture = Self.fixture(for: host), let url = request.url else {
      client?.urlProtocol(self, didFailWithError: NetworkGuardError.blocked)
      return
    }

    let response = HTTPURLResponse(
      url: url,
      statusCode: fixture.statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: fixture.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  public override func stopLoading() {}
}
