import Foundation
import Network
import Synchronization

/// A loopback-only HTTP/1.1 server for tests that need the real `URLSession` stack: redirect
/// delegates, incremental body delivery, and sockets that stay open or close on demand.
///
/// It binds `127.0.0.1` on an ephemeral port, answers from registered routes, and records every
/// request. Nothing leaves the machine and no external service is involved. A test suite may skip it
/// by setting `OPENCODE_SKIP_LOOPBACK_FIXTURES`, so an environment that forbids sockets stays green.
public final class LocalHTTPServer: @unchecked Sendable {
  public struct Request: Sendable, Equatable {
    public var method: String
    /// Path and query, exactly as sent.
    public var target: String
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public var path: String {
      String(target.split(separator: "?", maxSplits: 1).first ?? "")
    }
  }

  public enum Response: Sendable {
    case http(status: Int, headers: [String: String], body: Data)
    /// Chunked body, written with `intervalMilliseconds` between pieces, then the terminating chunk.
    case stream(headers: [String: String], chunks: [Data], intervalMilliseconds: Int)
    /// Accepts the request and never sends a status line or headers.
    case withholdHeaders
  }

  public enum ServerError: Error, Equatable, Sendable {
    case couldNotStart
  }

  private struct State {
    var routes: [String: Response] = [:]
    var requests: [Request] = []
    var closedConnections = 0
  }

  // Mutex-guarded state; the listener and connections live on one serial queue, and the class is
  // only a fixture, so the unchecked conformance covers the Network objects' own queues.
  private let state = Mutex(State())
  private let queue = DispatchQueue(label: "opencode.local-http-fixture")
  private let listener: NWListener
  public private(set) var port: UInt16 = 0

  public init() throws {
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let listener: NWListener
    do {
      listener = try NWListener(using: parameters)
    } catch {
      throw ServerError.couldNotStart
    }
    self.listener = listener

    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready, .failed, .cancelled:
        ready.signal()
      default:
        break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success, let assignedPort = listener.port?.rawValue else {
      listener.cancel()
      throw ServerError.couldNotStart
    }
    self.port = assignedPort
  }

  public var baseURL: URL {
    URL(string: "http://127.0.0.1:\(port)")!
  }

  public var requests: [Request] {
    state.withLock { $0.requests }
  }

  public var closedConnections: Int {
    state.withLock { $0.closedConnections }
  }

  public func route(_ path: String, _ response: Response) {
    state.withLock { $0.routes[path] = response }
  }

  /// Polls until a connection has closed, so a cancellation assertion fails with a timeout rather
  /// than a hang.
  public func waitForConnectionClosed(timeout: Duration) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if closedConnections > 0 { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return closedConnections > 0
  }

  public func stop() {
    listener.cancel()
    queue.sync {
      for connection in connections.values {
        connection.cancel()
      }
      connections.removeAll()
    }
  }

  // MARK: - Connections

  private var connections: [ObjectIdentifier: NWConnection] = [:]

  private func accept(_ connection: NWConnection) {
    queue.async { self.connections[ObjectIdentifier(connection)] = connection }
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled:
        self?.finish(connection)
      default:
        break
      }
    }
    connection.start(queue: queue)
    receiveHead(on: connection, buffer: Data())
  }

  private func receiveHead(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      var buffer = buffer
      if let data { buffer.append(data) }
      if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
        let head = Data(buffer[..<end.lowerBound])
        let body = Data(buffer[end.upperBound...])
        self.handle(head: head, body: body, on: connection)
        return
      }
      if isComplete || error != nil || buffer.count > 256 * 1024 {
        self.finish(connection)
        return
      }
      self.receiveHead(on: connection, buffer: buffer)
    }
  }

  private func handle(head: Data, body: Data, on connection: NWConnection) {
    guard let request = Self.parse(head: head, body: body) else {
      finish(connection)
      return
    }
    let response = state.withLock { state -> Response? in
      state.requests.append(request)
      return state.routes[request.path]
    }

    switch response {
    case .none:
      send(.http(status: 404, headers: [:], body: Data()), on: connection)
    case .some(let response):
      send(response, on: connection)
    }
  }

  private func send(_ response: Response, on connection: NWConnection) {
    switch response {
    case .http(let status, let headers, let body):
      writeHead(status: status, headers: headers, contentLength: body.count, on: connection)
      connection.send(content: body, isComplete: true, completion: .contentProcessed { [weak self] _ in
        self?.finish(connection)
      })
    case .stream(let headers, let chunks, let intervalMilliseconds):
      writeHead(status: 200, headers: headers, contentLength: nil, on: connection)
      watchForPeerClose(on: connection)
      sendChunks(chunks, index: 0, intervalMilliseconds: intervalMilliseconds, on: connection)
    case .withholdHeaders:
      // The request is recorded and the socket stays open without an answer. One pending read is
      // how the server notices the client giving up on it.
      watchForPeerClose(on: connection)
    }
  }

  private func writeHead(
    status: Int,
    headers: [String: String],
    contentLength: Int?,
    on connection: NWConnection
  ) {
    var lines = ["HTTP/1.1 \(status) \(Self.reason(status))"]
    var fields = headers
    fields["Connection"] = "close"
    if let contentLength {
      fields["Content-Length"] = String(contentLength)
    } else {
      fields["Transfer-Encoding"] = "chunked"
    }
    for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
      lines.append("\(name): \(value)")
    }
    let head = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    connection.send(content: head, completion: .contentProcessed { _ in })
  }

  private func sendChunks(
    _ chunks: [Data],
    index: Int,
    intervalMilliseconds: Int,
    on connection: NWConnection
  ) {
    guard index < chunks.count else {
      connection.send(
        content: Data("0\r\n\r\n".utf8),
        isComplete: true,
        completion: .contentProcessed { [weak self] _ in
          self?.finish(connection)
        }
      )
      return
    }
    let chunk = chunks[index]
    var framed = Data("\(String(chunk.count, radix: 16))\r\n".utf8)
    framed.append(chunk)
    framed.append(Data("\r\n".utf8))
    connection.send(content: framed, completion: .contentProcessed { [weak self] error in
      guard let self else { return }
      if error != nil {
        self.finish(connection)
        return
      }
      self.queue.asyncAfter(deadline: .now() + .milliseconds(intervalMilliseconds)) {
        self.sendChunks(chunks, index: index + 1, intervalMilliseconds: intervalMilliseconds, on: connection)
      }
    })
  }

  /// A chunked stream has no further request to read, so one pending read is how the server notices
  /// the client hanging up.
  private func watchForPeerClose(on connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, isComplete, error in
      if isComplete || error != nil {
        self?.finish(connection)
      }
    }
  }

  private func finish(_ connection: NWConnection) {
    queue.async {
      guard self.connections.removeValue(forKey: ObjectIdentifier(connection)) != nil else {
        return
      }
      self.state.withLock { $0.closedConnections += 1 }
      connection.cancel()
    }
  }

  private static func parse(head: Data, body: Data) -> Request? {
    let text = String(decoding: head, as: UTF8.self)
    let lines = text.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let parts = requestLine.split(separator: " ", maxSplits: 2)
    guard parts.count >= 2 else { return nil }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[name] = value
    }
    return Request(
      method: String(parts[0]),
      target: String(parts[1]),
      headers: headers,
      body: body
    )
  }

  private static func reason(_ status: Int) -> String {
    switch status {
    case 200: "OK"
    case 204: "No Content"
    case 302: "Found"
    case 401: "Unauthorized"
    case 404: "Not Found"
    default: "Status"
    }
  }
}
