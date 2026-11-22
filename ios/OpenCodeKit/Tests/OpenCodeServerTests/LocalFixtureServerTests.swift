import Foundation
import OpenCodeCore
import OpenCodeServer
import OpenCodeTestSupport
import Testing

/// These tests use a real `URLSession` against a loopback-only HTTP server, because a custom
/// `URLProtocol` cannot exercise the session's redirect delegate or a socket's lifetime.
///
/// Nothing leaves the machine. Set `OPENCODE_SKIP_LOOPBACK_FIXTURES=1` to skip the suite in an
/// environment that forbids sockets.
@Suite(
  "Local fixture server",
  .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["OPENCODE_SKIP_LOOPBACK_FIXTURES"] == nil)
)
struct LocalFixtureServerTests {
  private func liveTransport() -> HTTPTransport {
    let live = URLSessionTransport()
    return HTTPTransport(send: live.send, open: live.open)
  }

  private func openCodeServer(for address: String) -> OpenCodeServer {
    OpenCodeServer(url: address, username: "opencode", password: "token")
  }

  private var eventBody: [Data] {
    [
      Data("data: {\"type\":\"server.connected\"}\n\n".utf8),
      Data("data: {\"type\":\"session.deleted\",\"data\":{\"sessionID\":\"s1\"}}\n\n".utf8),
    ]
  }

  @Test("a same-origin redirect is followed with the credentials re-applied")
  func sameOriginRedirect() async throws {
    let server = try LocalHTTPServer()
    defer { server.stop() }
    server.route(
      "/final",
      .http(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"ok":true}"#.utf8))
    )
    server.route(
      "/start",
      .http(status: 302, headers: ["Location": "\(server.baseURL.absoluteString)/final"], body: Data())
    )

    let response = try await liveTransport().send(
      HTTPRequest(
        url: URL(string: "\(server.baseURL.absoluteString)/start")!,
        headers: ["Accept": "application/json"],
        authorization: "Basic c2VjcmV0"
      )
    )

    #expect(response.status == 200)
    #expect(response.body == Data(#"{"ok":true}"#.utf8))
    #expect(server.requests.map(\.path) == ["/start", "/final"])
    #expect(server.requests.allSatisfy { $0.headers["authorization"] == "Basic c2VjcmV0" })
  }

  @Test("a redirect to another origin is refused and the target never sees the credentials")
  func crossOriginRedirectIsRefused() async throws {
    let origin = try LocalHTTPServer()
    let target = try LocalHTTPServer()
    defer {
      origin.stop()
      target.stop()
    }
    origin.route(
      "/start",
      .http(status: 302, headers: ["Location": "\(target.baseURL.absoluteString)/steal"], body: Data())
    )
    target.route("/steal", .http(status: 200, headers: [:], body: Data("stolen".utf8)))

    await #expect(throws: TransportError.crossOriginRedirect) {
      _ = try await liveTransport().send(
        HTTPRequest(
          url: URL(string: "\(origin.baseURL.absoluteString)/start")!,
          authorization: "Basic c2VjcmV0"
        )
      )
    }

    #expect(target.requests.isEmpty)
    #expect(origin.requests.first?.headers["authorization"] == "Basic c2VjcmV0")
  }

  @Test("pairing refuses a redirect and never tries the other server")
  func pairingRefusesRedirect() async throws {
    let origin = try LocalHTTPServer()
    let target = try LocalHTTPServer()
    defer {
      origin.stop()
      target.stop()
    }
    let code = "Pair-123_xyz"
    origin.route(
      "/auth/connect/\(code)",
      .http(status: 302, headers: ["Location": "\(target.baseURL.absoluteString)/auth/connect/\(code)"], body: Data())
    )
    target.route(
      "/auth/connect/\(code)",
      .http(status: 200, headers: [:], body: Data(#"{"token":"1750000000.abcdefghijklmnopqrstuvwxyz"}"#.utf8))
    )

    let client = OpenCodeClient.live(transport: liveTransport(), clock: ClockClient.testValue)
    let link = try #require(
      PairingLink.decode(#"{"code":"\#(code)","urls":["\#(origin.baseURL.absoluteString)"]}"#)
    )

    do {
      _ = try await client.redeemPairing(link)
      Issue.record("expected the pairing redirect to be refused")
    } catch let error as OpenCodeClientError {
      #expect(error.statusCode == 302)
    }

    #expect(origin.requests.count == 1)
    #expect(origin.requests.first?.headers["authorization"] == nil)
    #expect(target.requests.isEmpty)
  }

  @Test("a server that withholds its headers fails the open by the connect deadline")
  func withheldHeadersHitTheDeadline() async throws {
    let server = try LocalHTTPServer()
    defer { server.stop() }
    server.route("/api/event", .withholdHeaders)

    let stream = EventStream(
      transport: liveTransport(),
      clock: .liveValue,
      connectDeadline: .milliseconds(250),
      idleDeadline: .seconds(30)
    )
    let started = ContinuousClock.now
    do {
      _ = try await stream.connect(server: openCodeServer(for: server.baseURL.absoluteString))
      Issue.record("expected the open to time out")
    } catch let error as OpenCodeClientError {
      #expect(error.transport == .timedOut)
    }
    let elapsed = ContinuousClock.now - started
    #expect(elapsed < .seconds(3))
    #expect(server.requests.count == 1)
    #expect(await server.waitForConnectionClosed(timeout: .seconds(2)))
  }

  @Test("cancelling while the headers are pending closes the connection")
  func cancellationWhileWaitingForHeaders() async throws {
    let server = try LocalHTTPServer()
    defer { server.stop() }
    server.route("/api/event", .withholdHeaders)

    let stream = EventStream(
      transport: liveTransport(),
      clock: .liveValue,
      connectDeadline: .seconds(30)
    )
    let task = Task {
      try await stream.connect(server: self.openCodeServer(for: server.baseURL.absoluteString))
    }
    try await Task.sleep(for: .milliseconds(80))
    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    #expect(await server.waitForConnectionClosed(timeout: .seconds(3)))
  }

  @Test("a web-page API answer is classified as incompatible")
  func webPageAPIAnswer() async throws {
    let server = try LocalHTTPServer()
    defer { server.stop() }
    server.route(
      "/api/info",
      .http(status: 200, headers: ["Content-Type": "text/html"], body: Data("<!doctype html>".utf8))
    )

    let client = OpenCodeClient.live(transport: liveTransport(), clock: ClockClient.testValue)
    do {
      _ = try await client.health(openCodeServer(for: server.baseURL.absoluteString))
      Issue.record("expected an incompatible-API failure")
    } catch let error as OpenCodeClientError {
      #expect(error.failure == .incompatibleAPI(feature: "server info"))
      #expect(error.copy == ServerCopy.incompatibleAPI)
    }
  }

  @Test("a chunk-buffer overflow is a typed, recoverable error")
  func chunkBufferOverflow() async throws {
    let server = try LocalHTTPServer()
    defer { server.stop() }
    let block = Data(repeating: 0x41, count: 256 * 1024)
    server.route(
      "/api/event",
      .stream(
        headers: ["Content-Type": "text/event-stream"],
        chunks: [block, block, block],
        intervalMilliseconds: 40
      )
    )

    let transport = URLSessionTransport(chunkCapacity: 1)
    let stream = try await transport.open(
      HTTPRequest(url: URL(string: "\(server.baseURL.absoluteString)/api/event")!)
    )
    // Do not read for a moment, so more than one chunk arrives at a capacity of one.
    try await Task.sleep(for: .milliseconds(400))

    do {
      for try await _ in stream.chunks {}
      Issue.record("expected the chunk buffer to overflow")
    } catch let error as TransportError {
      #expect(error == .streamOverflow)
    }
    #expect(await server.waitForConnectionClosed(timeout: .seconds(3)))
  }

  @Test("a rejected stream response closes its connection")
  func rejectedResponseClosesTheConnection() async throws {
    let server = try LocalHTTPServer()
    defer { server.stop() }
    server.route("/api/event", .http(status: 401, headers: [:], body: Data()))

    let stream = EventStream(transport: liveTransport(), clock: .liveValue)
    await #expect(throws: OpenCodeClientError.self) {
      _ = try await stream.connect(server: openCodeServer(for: server.baseURL.absoluteString))
    }
    #expect(await server.waitForConnectionClosed(timeout: .seconds(2)))
  }

  @Test("a consumer that stops stops the underlying request")
  func consumerShutdownClosesTheSocket() async throws {
    let server = try LocalHTTPServer()
    defer { server.stop() }
    server.route(
      "/api/event",
      .stream(
        headers: ["Content-Type": "text/event-stream"],
        chunks: eventBody,
        intervalMilliseconds: 120
      )
    )

    let stream = EventStream(
      transport: liveTransport(),
      clock: .liveValue,
      idleDeadline: .seconds(30)
    )
    let connection = try await stream.connect(server: openCodeServer(for: server.baseURL.absoluteString))

    let consumer = Task {
      for try await _ in connection.events {}
    }
    // Let the request open and the first event arrive, then shut the consumer down while it waits.
    try await Task.sleep(for: .milliseconds(60))
    consumer.cancel()
    _ = try? await consumer.value

    #expect(await server.waitForConnectionClosed(timeout: .seconds(3)))
  }

  @Test("closing a connection stops the underlying request")
  func explicitCloseStopsTheRequest() async throws {
    let server = try LocalHTTPServer()
    defer { server.stop() }
    server.route(
      "/api/event",
      .stream(
        headers: ["Content-Type": "text/event-stream"],
        chunks: eventBody,
        intervalMilliseconds: 120
      )
    )

    let stream = EventStream(
      transport: liveTransport(),
      clock: .liveValue,
      idleDeadline: .seconds(30)
    )
    let connection = try await stream.connect(server: openCodeServer(for: server.baseURL.absoluteString))
    connection.close()

    #expect(await server.waitForConnectionClosed(timeout: .seconds(3)))
  }

  @Test("a compatible fixture server serves health, projects and the event handshake")
  func compatibleFixtureConnection() async throws {
    let server = try LocalHTTPServer()
    defer { server.stop() }
    server.route(
      "/api/info",
      .http(
        status: 200,
        headers: ["Content-Type": "application/json"],
        body: Data(#"{"version":"0.0.0-fixture","pid":1}"#.utf8)
      )
    )
    server.route(
      "/api/project",
      .http(
        status: 200,
        headers: ["Content-Type": "application/json"],
        body: Data(
          #"[{"id":"p1","canonical":"/work/box","name":"Box"}]"#.utf8
        )
      )
    )
    server.route(
      "/api/event",
      .stream(
        headers: ["Content-Type": "text/event-stream"],
        chunks: [Data("data: {\"type\":\"server.connected\"}\n\n".utf8)],
        intervalMilliseconds: 10
      )
    )

    let serverValue = openCodeServer(for: server.baseURL.absoluteString)
    let client = OpenCodeClient.live(
      transport: liveTransport(),
      clock: .liveValue,
      policy: .once
    )

    let info = try await client.health(serverValue)
    let projects = try await client.projects(serverValue)

    var connected = false
    for try await event in client.events(serverValue, { _ in }) {
      if event == .connected {
        connected = true
        break
      }
    }

    #expect(info.version == "0.0.0-fixture")
    #expect(projects.map(\.name) == ["Box"])
    #expect(connected)
    #expect(server.requests.map(\.path).contains("/api/info"))
    #expect(server.requests.map(\.path).contains("/api/project"))
    #expect(server.requests.map(\.path).contains("/api/event"))
  }
}
