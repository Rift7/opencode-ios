import Foundation
import OpenCodeCore
import OpenCodeServer
import Testing

@Suite("Event stream")
struct EventStreamTests {
  private let server = OpenCodeServer(url: "http://10.0.0.2:4096", username: "opencode", password: "token")

  private func streamTransport(
    log: RequestLog = RequestLog(),
    _ handler: @escaping @Sendable (HTTPRequest, Int) async throws -> HTTPStream
  ) -> HTTPTransport {
    HTTPTransport(
      send: { _ in throw TransportError.blocked },
      open: { request in
        log.append(request)
        return try await handler(request, log.requests.count)
      }
    )
  }

  /// A response whose body is `chunks`, delivered in order and then ended.
  private func response(
    status: Int = 200,
    chunks: [String],
    url: URL = URL(string: "http://10.0.0.2:4096/api/event")!
  ) -> HTTPStream {
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    for chunk in chunks {
      continuation.yield(Data(chunk.utf8))
    }
    continuation.finish()
    return HTTPStream(status: status, headers: [:], finalURL: url, chunks: stream)
  }

  private func collect(
    _ events: AsyncThrowingStream<ServerEvent, any Error>,
    count: Int
  ) async throws -> [ServerEvent] {
    var result: [ServerEvent] = []
    for try await event in events {
      result.append(event)
      if result.count == count { break }
    }
    return result
  }

  @Test("a connection sends the stream request and decodes fragmented frames")
  func decodesFragments() async throws {
    let log = RequestLog()
    let transport = streamTransport(log: log) { _, _ in
      self.response(chunks: [
        "data: {\"type\":\"server.con",
        "nected\"}\n\n: heartbeat\n\ndata: {\"type\":\"session.deleted\",\"data\":{\"sessionID\":\"s1\"}}\n\n",
      ])
    }
    let stream = EventStream(transport: transport, clock: ClockClient.testValue, enabledWatchdog: false)
    let events = try await stream.connect(server: server)
    let received = try await collect(events, count: 2)

    #expect(received == [.connected, .sessionDeleted(sessionID: "s1")])
    let request = try #require(log.requests.first)
    #expect(request.url.path == "/api/event")
    #expect(request.headers["Accept"] == "text/event-stream")
    #expect(request.headers["X-OpenCode-Capabilities"] == "experimental-media-uri")
    #expect(request.authorization == "Basic b3BlbmNvZGU6dG9rZW4=")
  }

  @Test("a 401 fails the connection with the rejected-credentials status")
  func unauthorized() async throws {
    let transport = streamTransport { _, _ in self.response(status: 401, chunks: []) }
    let stream = EventStream(transport: transport, clock: ClockClient.testValue, enabledWatchdog: false)

    do {
      _ = try await stream.connect(server: server)
      Issue.record("expected a failure")
    } catch let error as OpenCodeClientError {
      #expect(error.statusCode == 401)
    }
  }

  @Test("an end of input is an error so the owner reconnects")
  func endOfInput() async throws {
    let transport = streamTransport { _, _ in self.response(chunks: []) }
    let stream = EventStream(transport: transport, clock: ClockClient.testValue, enabledWatchdog: false)
    let events = try await stream.connect(server: server)

    do {
      for try await _ in events {}
      Issue.record("expected the stream to end with an error")
    } catch let error as OpenCodeClientError {
      #expect(error.failure == .streamEnded)
      #expect(error.copy == "The event stream ended.")
    }
  }

  @Test("a consumer that falls behind ends with an overflow")
  func overflow() async throws {
    let transport = streamTransport { _, _ in
      self.response(chunks: [
        "data: {\"type\":\"session.deleted\",\"data\":{\"sessionID\":\"s1\"}}\n\n"
          + "data: {\"type\":\"session.deleted\",\"data\":{\"sessionID\":\"s2\"}}\n\n"
          + "data: {\"type\":\"session.deleted\",\"data\":{\"sessionID\":\"s3\"}}\n\n"
      ])
    }
    let stream = EventStream(transport: transport, clock: ClockClient.testValue, capacity: 1, enabledWatchdog: false)
    let events = try await stream.connect(server: server)
    // Let the reader produce into an unconsumed channel, so the bound is what fails the stream.
    try await Task.sleep(for: .milliseconds(50))

    var received: [ServerEvent] = []
    do {
      for try await event in events {
        received.append(event)
      }
      Issue.record("expected an overflow")
    } catch {
      #expect(error is EventStreamOverflow)
    }
    #expect(received.count <= 1)
  }

  @Test("a server failure frame ends the connection")
  func serverFailureFrame() async throws {
    let transport = streamTransport { _, _ in
      self.response(chunks: ["data: {\"_tag\":\"UnknownError\"}\n\n"])
    }
    let stream = EventStream(transport: transport, clock: ClockClient.testValue, enabledWatchdog: false)
    let events = try await stream.connect(server: server)

    do {
      for try await _ in events {}
      Issue.record("expected a failure")
    } catch let error as OpenCodeClientError {
      #expect(error.failure == .streamServerFailure)
    }
  }

  @Test("the runner reconnects after a failed connection and keeps the events")
  func runnerReconnects() async throws {
    let clock = ClockClient.recording()
    let log = RequestLog()
    let transport = streamTransport(log: log) { _, index in
      if index == 1 { throw URLError(.timedOut) }
      return self.response(chunks: [
        "data: {\"type\":\"server.connected\"}\n\ndata: {\"type\":\"session.deleted\",\"data\":{\"sessionID\":\"s1\"}}\n\n"
      ])
    }
    let runner = EventStreamRunner(
      stream: EventStream(transport: transport, clock: clock.client, enabledWatchdog: false),
      environment: .online(unit: 0)
    )
    let received = try await collect(runner.events(server: server), count: 2)

    #expect(received == [.connected, .sessionDeleted(sessionID: "s1")])
    #expect(log.requests.count >= 2)
    #expect(clock.sleeps.count >= 1)
  }

  @Test("a single 401 ends the reconnect loop")
  func runnerStopsOn401() async throws {
    let clock = ClockClient.recording()
    let log = RequestLog()
    let transport = streamTransport(log: log) { _, _ in self.response(status: 401, chunks: []) }
    let runner = EventStreamRunner(
      stream: EventStream(transport: transport, clock: clock.client, enabledWatchdog: false),
      environment: .online(unit: 0)
    )

    do {
      for try await _ in runner.events(server: server) {}
      Issue.record("expected a failure")
    } catch let error as OpenCodeClientError {
      #expect(error.statusCode == 401)
    }
    #expect(log.requests.count == 1)
    #expect(clock.sleeps.isEmpty)
  }

  @Test("an ended connection is retried, then the loop continues")
  func runnerRetriesAfterEndedStream() async throws {
    let clock = ClockClient.recording()
    let log = RequestLog()
    let transport = streamTransport(log: log) { _, index in
      if index == 1 { return self.response(chunks: []) }
      return self.response(chunks: ["data: {\"type\":\"server.connected\"}\n\n"])
    }
    let runner = EventStreamRunner(
      stream: EventStream(transport: transport, clock: clock.client, enabledWatchdog: false),
      environment: .online(unit: 0)
    )
    let received = try await collect(runner.events(server: server), count: 1)

    #expect(received == [.connected])
    #expect(log.requests.count >= 2)
    #expect(clock.sleeps.count >= 1)
  }

  @Test("the watchdog ends a silent connection as a timeout")
  func watchdogTimesOut() async throws {
    // No chunks and no finish: the connection stays open, and the test clock advances past the
    // connect deadline because the scripted sleep returns at once.
    let (chunks, _) = AsyncThrowingStream<Data, any Error>.makeStream()
    let transport = streamTransport { _, _ in
      HTTPStream(
        status: 200,
        headers: [:],
        finalURL: URL(string: "http://10.0.0.2:4096/api/event")!,
        chunks: chunks
      )
    }
    let stream = EventStream(
      transport: transport,
      clock: ClockClient.recording().client,
      connectDeadline: .milliseconds(1),
      idleDeadline: .milliseconds(2)
    )
    let events = try await stream.connect(server: server)

    do {
      for try await _ in events {}
      Issue.record("expected a timeout")
    } catch let error as OpenCodeClientError {
      #expect(error.transport == .timedOut)
    }
  }
}
