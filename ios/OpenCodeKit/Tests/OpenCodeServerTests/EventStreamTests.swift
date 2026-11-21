import Foundation
import OpenCodeCore
import OpenCodeServer
import Synchronization
import Testing

/// Counts explicit connection closes, so a test can prove a previous connection was torn down.
final class CloseCounter: Sendable {
  private let state = Mutex(0)

  var count: Int { state.withLock { $0 } }

  func increment() { state.withLock { $0 += 1 } }
}

final class OverflowRecorder: Sendable {
  private let state = Mutex<[EventStreamOverflow]>([])

  var overflows: [EventStreamOverflow] { state.withLock { $0 } }

  func record(_ overflow: EventStreamOverflow) { state.withLock { $0.append(overflow) } }
}

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
    close: CloseCounter? = nil,
    url: URL = URL(string: "http://10.0.0.2:4096/api/event")!
  ) -> HTTPStream {
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    for chunk in chunks {
      continuation.yield(Data(chunk.utf8))
    }
    continuation.finish()
    return HTTPStream(
      status: status,
      headers: [:],
      finalURL: url,
      chunks: stream,
      close: { close?.increment() }
    )
  }

  /// A response whose body stays open until the test finishes it, for shutdown tests.
  private func openResponse(
    channel: BoundedChannel<Data>,
    close: CloseCounter
  ) -> HTTPStream {
    HTTPStream(
      status: 200,
      headers: [:],
      finalURL: URL(string: "http://10.0.0.2:4096/api/event")!,
      chunks: channel.stream,
      close: { close.increment() }
    )
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
    let stream = EventStream(transport: transport, clock: .suspended, enabledWatchdog: false)
    let connection = try await stream.connect(server: server)
    let received = try await collect(connection.events, count: 2)

    #expect(received == [.connected, .sessionDeleted(sessionID: "s1")])
    let request = try #require(log.requests.first)
    #expect(request.url.path == "/api/event")
    #expect(request.headers["Accept"] == "text/event-stream")
    #expect(request.headers["X-OpenCode-Capabilities"] == "experimental-media-uri")
    #expect(request.authorization == "Basic b3BlbmNvZGU6dG9rZW4=")
  }

  @Test("a rejected response fails the open and closes the response")
  func rejectedResponseCloses() async throws {
    let close = CloseCounter()
    let transport = streamTransport { _, _ in self.response(status: 401, chunks: [], close: close) }
    let stream = EventStream(transport: transport, clock: .suspended, enabledWatchdog: false)

    do {
      _ = try await stream.connect(server: server)
      Issue.record("expected a failure")
    } catch let error as OpenCodeClientError {
      #expect(error.statusCode == 401)
      #expect(error.copy == "The server rejected these credentials.")
    }
    #expect(close.count == 1)
  }

  @Test("a non-2xx stream fails and closes the response")
  func nonSuccessCloses() async throws {
    let close = CloseCounter()
    let transport = streamTransport { _, _ in self.response(status: 503, chunks: [], close: close) }
    let stream = EventStream(transport: transport, clock: .suspended, enabledWatchdog: false)
    await #expect(throws: OpenCodeClientError.self) {
      _ = try await stream.connect(server: server)
    }
    #expect(close.count == 1)
  }

  @Test("an end of input is an error so the owner reconnects")
  func endOfInput() async throws {
    let transport = streamTransport { _, _ in self.response(chunks: []) }
    let stream = EventStream(transport: transport, clock: .suspended, enabledWatchdog: false)
    let connection = try await stream.connect(server: server)

    do {
      for try await _ in connection.events {}
      Issue.record("expected the stream to end with an error")
    } catch let error as OpenCodeClientError {
      #expect(error.failure == .streamEnded)
      #expect(error.copy == "The event stream ended.")
    }
  }

  @Test("a server failure frame ends the connection")
  func serverFailureFrame() async throws {
    let transport = streamTransport { _, _ in
      self.response(chunks: ["data: {\"_tag\":\"UnknownError\"}\n\n"])
    }
    let stream = EventStream(transport: transport, clock: .suspended, enabledWatchdog: false)
    let connection = try await stream.connect(server: server)

    do {
      for try await _ in connection.events {}
      Issue.record("expected a failure")
    } catch let error as OpenCodeClientError {
      #expect(error.failure == .streamServerFailure)
    }
  }

  @Test("a consumer that falls behind ends with an explicit overflow and a closed connection")
  func overflow() async throws {
    let close = CloseCounter()
    let transport = streamTransport { _, _ in
      self.response(chunks: [
        "data: {\"type\":\"session.deleted\",\"data\":{\"sessionID\":\"s1\"}}\n\n"
          + "data: {\"type\":\"session.deleted\",\"data\":{\"sessionID\":\"s2\"}}\n\n"
          + "data: {\"type\":\"session.deleted\",\"data\":{\"sessionID\":\"s3\"}}\n\n"
      ], close: close)
    }
    let stream = EventStream(
      transport: transport,
      clock: .suspended,
      capacity: 1,
      enabledWatchdog: false
    )
    let connection = try await stream.connect(server: server)
    // Let the reader produce into an unconsumed channel, so the bound is what fails the stream.
    try await Task.sleep(for: .milliseconds(50))

    var received: [ServerEvent] = []
    do {
      for try await event in connection.events {
        received.append(event)
      }
      Issue.record("expected an overflow")
    } catch let overflow as EventStreamOverflow {
      #expect(overflow.cause == .consumerFellBehind)
    }
    #expect(received.count <= 1)
    let closed = await Self.waitUntil { close.count > 0 }
    #expect(closed)
  }

  @Test("consumer shutdown stops the underlying response")
  func consumerShutdownClosesResponse() async throws {
    let close = CloseCounter()
    let channel = BoundedChannel<Data>(capacity: 8)
    let transport = streamTransport { _, _ in self.openResponse(channel: channel, close: close) }
    let stream = EventStream(transport: transport, clock: .suspended, enabledWatchdog: false)
    let connection = try await stream.connect(server: server)

    channel.push(Data("data: {\"type\":\"server.connected\"}\n\n".utf8))
    let consumer = Task {
      for try await _ in connection.events {}
    }
    // Give the consumer the first event, then shut it down while it waits for the next.
    try await Task.sleep(for: .milliseconds(30))
    consumer.cancel()
    _ = try? await consumer.value

    let closed = await Self.waitUntil { close.count > 0 }
    #expect(closed)
  }

  @Test("the watchdog ends a silent connection as a timeout")
  func watchdogTimesOut() async throws {
    let (chunks, _) = AsyncThrowingStream<Data, any Error>.makeStream()
    let transport = streamTransport { _, _ in
      HTTPStream(
        status: 200,
        headers: [:],
        finalURL: URL(string: "http://10.0.0.2:4096/api/event")!,
        chunks: chunks,
        close: {}
      )
    }
    let stream = EventStream(
      transport: transport,
      clock: ClockClient.recording().client,
      connectDeadline: nil,
      idleDeadline: .milliseconds(2)
    )
    let connection = try await stream.connect(server: server)

    do {
      for try await _ in connection.events {}
      Issue.record("expected a timeout")
    } catch let error as OpenCodeClientError {
      #expect(error.transport == .timedOut)
    }
  }

  private static func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @Sendable () -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }
}

@Suite("Event stream runner")
struct EventStreamRunnerTests {
  private let server = OpenCodeServer(url: "http://10.0.0.2:4096")

  /// A connection that yields `events` and then stays open, so the runner waits instead of
  /// reconnecting again while a test asserts.
  private func lingeringConnection(_ events: [ServerEvent], close: CloseCounter? = nil) -> EventConnection {
    let channel = BoundedChannel<ServerEvent>(capacity: max(1, events.count))
    for event in events {
      channel.push(event)
    }
    return EventConnection(
      events: channel.stream,
      close: {
        channel.cancel()
        close?.increment()
      }
    )
  }

  private func connection(
    _ events: [ServerEvent],
    then error: (any Error)? = nil,
    close: CloseCounter? = nil
  ) -> EventConnection {
    let (stream, continuation) = AsyncThrowingStream<ServerEvent, any Error>.makeStream()
    for event in events {
      continuation.yield(event)
    }
    continuation.finish(throwing: error)
    return EventConnection(events: stream, close: { close?.increment() })
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

  @Test("a failed connection is retried and the next connection's events arrive")
  func reconnectsAfterFailure() async throws {
    let clock = ClockClient.recording()
    let attempts = AttemptCounter()
    let runner = EventStreamRunner(
      clock: clock.client,
      connect: { _ in
        let attempt = attempts.next()
        if attempt == 1 { throw URLError(.timedOut) }
        return self.lingeringConnection([.connected, .sessionDeleted(sessionID: "s1")])
      },
      environment: .online(unit: 0)
    )

    let received = try await collect(runner.events(server: server), count: 2)
    #expect(received == [.connected, .sessionDeleted(sessionID: "s1")])
    #expect(attempts.value == 2)
    #expect(clock.sleeps.count == 1)
  }

  @Test("a single 401 ends the reconnect loop")
  func stopsOn401() async throws {
    let clock = ClockClient.recording()
    let attempts = AttemptCounter()
    let runner = EventStreamRunner(
      clock: clock.client,
      connect: { _ in
        _ = attempts.next()
        throw OpenCodeClientError(.status(401))
      },
      environment: .online(unit: 0)
    )

    do {
      for try await _ in runner.events(server: server) {}
      Issue.record("expected a failure")
    } catch let error as OpenCodeClientError {
      #expect(error.statusCode == 401)
    }
    #expect(attempts.value == 1)
    #expect(clock.sleeps.isEmpty)
  }

  @Test("an overflow closes the connection, resynchronizes, then reconnects")
  func overflowRecoversAndReconnects() async throws {
    let clock = ClockClient.recording()
    let attempts = AttemptCounter()
    let firstClose = CloseCounter()
    let secondClose = CloseCounter()
    let resyncs = OverflowRecorder()

    let runner = EventStreamRunner(
      clock: clock.client,
      connect: { _ in
        let attempt = attempts.next()
        if attempt == 1 {
          // The connection delivered a projection, then its consumer fell behind.
          return self.connection(
            [.connected, .sessionDeleted(sessionID: "old")],
            then: EventStreamOverflow(),
            close: firstClose
          )
        }
        return self.lingeringConnection(
          [.connected, .sessionDeleted(sessionID: "new")],
          close: secondClose
        )
      },
      environment: .online(unit: 0),
      maximumConsecutiveOverflows: 5,
      onResynchronize: { resyncs.record($0) }
    )

    let received = try await collect(runner.events(server: server), count: 4)

    #expect(received.count == 4)
    #expect(received.last == .sessionDeleted(sessionID: "new"))
    #expect(resyncs.overflows.map(\.cause) == [.consumerFellBehind])
    #expect(firstClose.count == 1)
    #expect(attempts.value == 2)
    #expect(clock.sleeps.count == 1)
  }

  @Test("consecutive overflows are bounded, then the stream ends with the overflow")
  func overflowsAreBounded() async throws {
    let clock = ClockClient.recording()
    let attempts = AttemptCounter()
    let resyncs = OverflowRecorder()
    let runner = EventStreamRunner(
      clock: clock.client,
      connect: { _ in
        _ = attempts.next()
        return self.connection([], then: EventStreamOverflow())
      },
      environment: .online(unit: 0),
      maximumConsecutiveOverflows: 2,
      onResynchronize: { resyncs.record($0) }
    )

    do {
      for try await _ in runner.events(server: server) {}
      Issue.record("expected the runner to give up")
    } catch let overflow as EventStreamOverflow {
      #expect(overflow.cause == .consumerFellBehind)
    }
    #expect(attempts.value == 3)
    #expect(resyncs.overflows.count == 2)
  }

  @Test("a completed connection's close runs before the next one opens")
  func closesBeforeReconnect() async throws {
    let clock = ClockClient.recording()
    let firstClose = CloseCounter()
    let attempts = AttemptCounter()
    let runner = EventStreamRunner(
      clock: clock.client,
      connect: { _ in
        let attempt = attempts.next()
        if attempt == 1 {
          return self.connection([.connected], then: OpenCodeClientError(.streamEnded), close: firstClose)
        }
        return self.lingeringConnection([.connected, .sessionDeleted(sessionID: "s1")])
      },
      environment: .online(unit: 0)
    )

    _ = try await collect(runner.events(server: server), count: 3)
    #expect(firstClose.count == 1)
    #expect(attempts.value == 2)
  }
}

/// A thread-safe attempt counter shared by the scripted connections above.
final class AttemptCounter: Sendable {
  private let state = Mutex(0)

  var value: Int { state.withLock { $0 } }

  @discardableResult
  func next() -> Int {
    state.withLock { value in
      value += 1
      return value
    }
  }
}
