import Foundation
import Network

/// A loopback-only page for the in-app browser journeys. The simulator's test runner and the app
/// share this machine's loopback interface, so the page never reaches the real network.
final class BrowserFixtureServer: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "opencode.browser-fixture")
  private let lock = NSLock()
  private var connections: [ObjectIdentifier: NWConnection] = [:]

  private(set) var port: UInt16 = 0

  init() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let listener = try NWListener(using: parameters)
    self.listener = listener
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
      if case .ready = state { ready.signal() }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
      listener.cancel()
      throw URLError(.cannotConnectToHost)
    }
    self.port = port
  }

  var baseURL: String { "http://127.0.0.1:\(port)" }
  var documentURL: String { "\(baseURL)/docs" }

  func stop() {
    listener.cancel()
    lock.lock()
    let all = connections.values
    connections.removeAll()
    lock.unlock()
    for connection in all { connection.cancel() }
  }

  private func accept(_ connection: NWConnection) {
    lock.lock()
    connections[ObjectIdentifier(connection)] = connection
    lock.unlock()
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled:
        self?.finish(connection)
      default:
        break
      }
    }
    connection.start(queue: queue)
    receive(on: connection, buffer: Data())
  }

  private func receive(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
      guard let self else { return }
      var buffer = buffer
      if let data { buffer.append(data) }
      if buffer.range(of: Data("\r\n\r\n".utf8)) != nil || complete || error != nil {
        handle(buffer, on: connection)
        return
      }
      if buffer.count > 64 * 1024 {
        finish(connection)
        return
      }
      receive(on: connection, buffer: buffer)
    }
  }

  private func handle(_ request: Data, on connection: NWConnection) {
    let head = String(decoding: request.prefix(4_096), as: UTF8.self)
    let path = head.split(separator: "\r\n").first?
      .split(separator: " ").dropFirst().first.map(String.init) ?? "/"
    if path.hasPrefix("/redirect") {
      send(
        "HTTP/1.1 302 Found\r\nLocation: /docs\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        on: connection
      )
      return
    }
    let body = """
      <!doctype html><html><head><meta charset="utf-8">
      <title>Browser Fixture</title>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>body{font:17px -apple-system;padding:24px;color:#111}a{color:#2563eb}</style>
      </head><body>
      <h1>Local fixture</h1>
      <p>This page is served on loopback for the media browser journey.</p>
      <p><a href="/redirect">Same-origin redirect</a></p>
      </body></html>
      """
    let data = Data(body.utf8)
    send(
      "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n",
      body: data,
      on: connection
    )
  }

  private func send(_ head: String, body: Data = Data(), on connection: NWConnection) {
    var payload = Data(head.utf8)
    payload.append(body)
    connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
      self?.finish(connection)
    })
  }

  private func finish(_ connection: NWConnection) {
    connection.cancel()
    lock.lock()
    connections[ObjectIdentifier(connection)] = nil
    lock.unlock()
  }
}
