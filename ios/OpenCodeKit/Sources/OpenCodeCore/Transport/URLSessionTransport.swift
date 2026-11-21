import Foundation
import Synchronization

/// The live transport: one ephemeral `URLSession`, no cookies, no cache, manual redirect control and
/// incremental body delivery.
public struct URLSessionTransport: Sendable {
  /// Chunks a stream may buffer before the connection is failed. URLSession hands over at most
  /// 16 KiB per callback, so this is roughly 1 MiB.
  public static let streamChunkCapacity = 64

  private let makeConfiguration: @Sendable () -> URLSessionConfiguration

  public init(configuration: @escaping @Sendable () -> URLSessionConfiguration = URLSessionTransport.ephemeralConfiguration) {
    self.makeConfiguration = configuration
  }

  public static func ephemeralConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.waitsForConnectivity = false
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 600
    return configuration
  }

  public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    try checkCleartext(request.url)
    let urlRequest = try request.wireRequest()
    let redirects = RedirectGuard(request: request)
    let (data, response) = try await URLSession(configuration: makeConfiguration())
      .data(for: urlRequest, delegate: redirects)
    if redirects.didRefuseCrossOrigin {
      throw TransportError.crossOriginRedirect
    }
    guard let http = response as? HTTPURLResponse else {
      throw TransportError.invalidRequest
    }
    return HTTPResponse(
      status: http.statusCode,
      headers: http.lowercasedHeaders,
      body: data,
      finalURL: http.url ?? request.url
    )
  }

  public func open(_ request: HTTPRequest) async throws -> HTTPStream {
    try checkCleartext(request.url)
    let urlRequest = try request.wireRequest()
    let channel = BoundedChannel<Data>(capacity: Self.streamChunkCapacity)
    let receiver = StreamReceiver(request: request, channel: channel)
    let session = URLSession(configuration: makeConfiguration(), delegate: receiver, delegateQueue: nil)
    return try await withTaskCancellationHandler {
      try await receiver.start(session: session, request: urlRequest)
    } onCancel: {
      receiver.cancel()
    }
  }

  private func checkCleartext(_ url: URL) throws {
    guard TransportSecurity.allowsInsecureHTTP(url: url) else {
      throw TransportError.insecureHTTP
    }
  }
}

// MARK: - Requests

extension HTTPRequest {
  func wireRequest() throws -> URLRequest {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      throw TransportError.invalidRequest
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = timeout
    request.httpBody = body
    for (name, value) in wireHeaders {
      request.setValue(value, forHTTPHeaderField: name)
    }
    return request
  }
}

extension HTTPURLResponse {
  var lowercasedHeaders: [String: String] {
    var headers: [String: String] = [:]
    for (name, value) in allHeaderFields {
      guard let name = name as? String, let value = value as? String else { continue }
      headers[name.lowercased()] = value
    }
    return headers
  }
}

/// Scheme, host and effective port: the unit a credential is bound to.
public struct HTTPOrigin: Sendable, Equatable {
  public let scheme: String
  public let host: String
  public let port: Int

  public init?(_ url: URL) {
    guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return nil }
    self.scheme = scheme
    self.host = host
    self.port = url.port ?? (scheme == "https" ? 443 : 80)
  }
}

/// A redirect target is only followed when it stays on the request's origin; the request's headers
/// are re-applied there. Anything else stops the redirect, and for a policy that would have followed
/// it the caller learns the request was refused rather than receiving a stranger's page.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  // URLSession calls the delegate on its own queue; the flag is Mutex-guarded.
  private struct State {
    var refusedCrossOrigin = false
  }

  private let rule: HTTPRedirectRule
  private let state = Mutex(State())

  init(request: HTTPRequest) {
    self.rule = HTTPRedirectRule(request: request)
  }

  var didRefuseCrossOrigin: Bool {
    state.withLock { $0.refusedCrossOrigin }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    switch rule.decide(request) {
    case .follow(let allowed):
      completionHandler(allowed)
    case .refuse:
      completionHandler(nil)
    case .refuseCrossOrigin:
      state.withLock { $0.refusedCrossOrigin = true }
      completionHandler(nil)
    }
  }
}

// MARK: - Streaming

private final class StreamReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  // URLSession owns the delegate queue; the continuation and task handles are Mutex-guarded, and
  // `push` must not await actor isolation or it would reorder body chunks.
  private enum Failure: Error {
    case overflow
  }

  private struct State {
    var continuation: CheckedContinuation<HTTPStream, any Error>?
    var responded = false
    var finished = false
  }

  private let request: HTTPRequest
  private let rule: HTTPRedirectRule
  private let channel: BoundedChannel<Data>
  private let state = Mutex(State())
  private var task: URLSessionDataTask?
  private var session: URLSession?

  init(request: HTTPRequest, channel: BoundedChannel<Data>) {
    self.request = request
    self.rule = HTTPRedirectRule(request: request)
    self.channel = channel
  }

  func start(session: URLSession, request urlRequest: URLRequest) async throws -> HTTPStream {
    try await withCheckedThrowingContinuation { continuation in
      state.withLock { $0.continuation = continuation }
      let task = session.dataTask(with: urlRequest)
      self.session = session
      self.task = task
      channel.setCloseHandler { [weak self] in
        self?.closeSocket()
      }
      task.resume()
    }
  }

  func cancel() {
    let continuation = state.withLock { state -> CheckedContinuation<HTTPStream, any Error>? in
      guard !state.finished else { return nil }
      state.finished = true
      let continuation = state.continuation
      state.continuation = nil
      return continuation
    }
    continuation?.resume(throwing: CancellationError())
    channel.cancel()
  }

  private func closeSocket() {
    task?.cancel()
    session?.invalidateAndCancel()
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      fail(TransportError.notAStream)
      completionHandler(.cancel)
      return
    }
    let stream = HTTPStream(
      status: http.statusCode,
      headers: http.lowercasedHeaders,
      finalURL: http.url ?? request.url,
      chunks: channel.stream
    )
    let continuation = state.withLock { state -> CheckedContinuation<HTTPStream, any Error>? in
      guard !state.finished else { return nil }
      state.responded = true
      let continuation = state.continuation
      state.continuation = nil
      return continuation
    }
    continuation?.resume(returning: stream)
    completionHandler(.allow)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    switch rule.decide(request) {
    case .follow(let allowed):
      completionHandler(allowed)
    case .refuse:
      completionHandler(nil)
    case .refuseCrossOrigin:
      fail(TransportError.crossOriginRedirect)
      completionHandler(nil)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    switch channel.push(data) {
    case .accepted:
      return
    case .closed:
      closeSocket()
    case .overflow:
      channel.fail(Failure.overflow)
      closeSocket()
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    if let error {
      fail(error)
    } else {
      state.withLock { state in
        if !state.responded { state.finished = true }
      }
      channel.finish()
    }
    session.finishTasksAndInvalidate()
  }

  private func fail(_ error: any Error) {
    let continuation = state.withLock { state -> CheckedContinuation<HTTPStream, any Error>? in
      guard !state.finished else { return nil }
      state.finished = true
      let continuation = state.continuation
      state.continuation = nil
      return continuation
    }
    if let continuation {
      continuation.resume(throwing: error)
    }
    channel.fail(error)
  }
}
