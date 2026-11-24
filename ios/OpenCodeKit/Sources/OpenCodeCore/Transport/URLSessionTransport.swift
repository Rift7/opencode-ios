import Foundation
import Synchronization

/// The live transport: no cookies, no cache, manual redirect control and incremental body delivery.
///
/// Session ownership:
/// - **Requests** share one lazy `URLSession` for the transport's lifetime. It has no delegate and is
///   never invalidated by a request; the connection closes when the transport does.
/// - **Streams** get one `URLSession` per connection, because the stream's data delegate is per
///   connection. It is invalidated as soon as the connection ends or is closed, so a dropped stream
///   cannot keep a socket or a task alive.
public struct URLSessionTransport: Sendable {
  /// Chunks a stream may buffer before the connection is failed. URLSession hands over at most
  /// 16 KiB per callback, so this is roughly 1 MiB.
  public static let streamChunkCapacity = 64

  private let makeConfiguration: @Sendable () -> URLSessionConfiguration
  private let requestSession = RequestSessionHolder()
  /// Test seam: a smaller buffer lets a test force the overflow this path must report.
  private let chunkCapacity: Int

  public init(
    configuration: @escaping @Sendable () -> URLSessionConfiguration = URLSessionTransport.ephemeralConfiguration,
    chunkCapacity: Int = URLSessionTransport.streamChunkCapacity
  ) {
    self.makeConfiguration = configuration
    self.chunkCapacity = max(1, chunkCapacity)
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
    try Task.checkCancellation()
    try checkCleartext(request.url)
    let urlRequest = try request.wireRequest()
    let redirects = RedirectGuard(request: request)
    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await requestSession.session(makeConfiguration)
        .data(for: urlRequest, delegate: redirects)
    } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
      throw CancellationError()
    }
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
    try Task.checkCancellation()
    try checkCleartext(request.url)
    let urlRequest = try request.wireRequest()
    let channel = BoundedChannel<Data>(capacity: chunkCapacity)
    let receiver = StreamReceiver(request: request, channel: channel)
    // The receiver owns this session from here on; every exit path invalidates it.
    let session = URLSession(configuration: makeConfiguration(), delegate: receiver, delegateQueue: nil)
    receiver.adopt(session: session)
    return try await withTaskCancellationHandler {
      try await receiver.start(request: urlRequest)
    } onCancel: {
      receiver.cancel()
    }
  }

  public func upload(
    _ request: HTTPRequest,
    fromFile fileURL: URL,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws -> HTTPResponse {
    try Task.checkCancellation()
    try checkCleartext(request.url)
    var urlRequest = try request.wireRequest()
    urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    let delegate = UploadReceiver(request: request, progress: progress)
    let session = URLSession(configuration: makeConfiguration(), delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await session.upload(for: urlRequest, fromFile: fileURL)
    } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
      throw CancellationError()
    }
    if delegate.didRefuseCrossOrigin {
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

  private func checkCleartext(_ url: URL) throws {
    guard TransportSecurity.allowsInsecureHTTP(url: url) else {
      throw TransportError.insecureHTTP
    }
  }
}

/// The one request session, created on first use and kept for the transport's lifetime.
private final class RequestSessionHolder: Sendable {
  // Mutex-guarded: `send` may run from several tasks at once.
  private let session = Mutex<URLSession?>(nil)

  func session(_ makeConfiguration: @Sendable () -> URLSessionConfiguration) -> URLSession {
    session.withLock { current in
      if let current { return current }
      let created = URLSession(configuration: makeConfiguration())
      current = created
      return created
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

/// Progress and redirect ownership for one file upload. URLSession calls the delegate on its own
/// queue; the cross-origin flag is Mutex-guarded.
private final class UploadReceiver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let rule: HTTPRedirectRule
  private let progress: @Sendable (Int64) -> Void
  private let refused = Mutex(false)

  init(request: HTTPRequest, progress: @escaping @Sendable (Int64) -> Void) {
    self.rule = HTTPRedirectRule(request: request)
    self.progress = progress
  }

  var didRefuseCrossOrigin: Bool {
    refused.withLock { $0 }
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
      refused.withLock { $0 = true }
      completionHandler(nil)
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64
  ) {
    progress(totalBytesSent)
  }
}

/// Scheme, host and effective port: the unit a credential is bound to.
public struct HTTPOrigin: Sendable, Equatable {  public let scheme: String
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

/// One streamed connection's delegate and startup state machine.
///
/// Startup can be cancelled at any point: before the receiver exists, between adopting the session
/// and registering the continuation, after registering it, or after the headers arrived. Every path
/// resumes the caller exactly once and invalidates the session.
private final class StreamReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private struct State {
    var continuation: CheckedContinuation<HTTPStream, any Error>?
    var session: URLSession?
    var task: URLSessionDataTask?
    var cancelled = false
    var responded = false
    var finished = false
  }

  private let request: HTTPRequest
  private let rule: HTTPRedirectRule
  private let channel: BoundedChannel<Data>
  private let state = Mutex(State())

  init(request: HTTPRequest, channel: BoundedChannel<Data>) {
    self.request = request
    self.rule = HTTPRedirectRule(request: request)
    self.channel = channel
  }

  /// Took ownership of `session`; cancellation and completion invalidate it.
  func adopt(session: URLSession) {
    let cancelled = state.withLock { state -> Bool in
      state.session = session
      return state.cancelled
    }
    if cancelled {
      session.invalidateAndCancel()
    }
  }

  func start(request urlRequest: URLRequest) async throws -> HTTPStream {
    try Task.checkCancellation()
    return try await withCheckedThrowingContinuation { continuation in
      let action = state.withLock { state -> Action in
        if state.cancelled || state.finished {
          return .refuseCancellation
        }
        state.continuation = continuation
        guard let session = state.session else { return .refuseCancellation }
        let task = session.dataTask(with: urlRequest)
        state.task = task
        return .start(task)
      }
      switch action {
      case .refuseCancellation:
        continuation.resume(throwing: CancellationError())
        cancel()
      case .start(let task):
        channel.setCloseHandler { [weak self] in
          self?.closeSocket()
        }
        task.resume()
      }
    }
  }

  private enum Action {
    case start(URLSessionDataTask)
    case refuseCancellation
  }

  /// Ends this connection: a pending startup resumes with cancellation, and a running one loses its
  /// socket. Idempotent.
  func cancel() {
    let action = state.withLock { state -> (CheckedContinuation<HTTPStream, any Error>?, URLSession?, URLSessionDataTask?) in
      let continuation = state.continuation
      let session = state.session
      let task = state.task
      state.cancelled = true
      state.finished = true
      state.continuation = nil
      state.task = nil
      state.session = nil
      return (continuation, session, task)
    }
    action.0?.resume(throwing: CancellationError())
    action.2?.cancel()
    action.1?.invalidateAndCancel()
    channel.cancel()
  }

  /// Explicit close from a caller that stopped reading.
  func close() {
    cancel()
  }

  private func closeSocket() {
    let handles = state.withLock { state -> (URLSession?, URLSessionDataTask?) in
      guard !state.finished else { return (nil, nil) }
      state.finished = true
      state.continuation = nil
      let handles = (state.session, state.task)
      state.session = nil
      state.task = nil
      return handles
    }
    handles.1?.cancel()
    handles.0?.invalidateAndCancel()
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
      chunks: channel.stream,
      close: { [weak self] in self?.close() }
    )
    let continuation = state.withLock { state -> CheckedContinuation<HTTPStream, any Error>?? in
      guard !state.finished, !state.cancelled else { return .some(nil) }
      state.responded = true
      let continuation = state.continuation
      state.continuation = nil
      return .some(continuation)
    }
    guard let continuation else {
      completionHandler(.cancel)
      close()
      return
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
      channel.fail(TransportError.streamOverflow)
      closeSocket()
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    let cancelled = state.withLock { $0.cancelled }
    if cancelled {
      session.invalidateAndCancel()
      return
    }
    if let error {
      fail(error)
    } else {
      let responded = state.withLock { state -> Bool in
        guard !state.finished else { return true }
        state.finished = true
        state.continuation = nil
        return state.responded
      }
      if !responded { resumeStart(.failure(TransportError.notAStream)) }
      channel.finish()
    }
    session.finishTasksAndInvalidate()
  }

  /// Resumes the pending startup exactly once.
  private func resumeStart(_ result: Result<HTTPStream, any Error>) {
    let continuation = state.withLock { state -> CheckedContinuation<HTTPStream, any Error>? in
      guard let continuation = state.continuation else { return nil }
      state.continuation = nil
      return continuation
    }
    continuation?.resume(with: result)
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
