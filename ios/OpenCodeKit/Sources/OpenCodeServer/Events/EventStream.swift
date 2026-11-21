import Foundation
import OpenCodeCore
import Synchronization

/// The event subscriber fell behind: the rest of this connection is incomplete.
///
/// This is the explicit signal to resynchronize from REST, which is authoritative. The connection is
/// already closed when it arrives; a consumer must not try to reconstruct a transcript from what it
/// saw before the overflow.
public struct EventStreamOverflow: Error, Equatable, Sendable {
  public enum Cause: Sendable, Equatable {
    /// The bounded hand-off to the consumer was full, so a delta would have been lost.
    case consumerFellBehind
  }

  public var cause: Cause

  public init(cause: Cause = .consumerFellBehind) {
    self.cause = cause
  }
}

/// An open SSE connection: its events and the one way to close it.
///
/// `close` is idempotent. It cancels the read, the watchdog and the underlying request's session,
/// and ends the event stream. A consumer that stops reading, throws, or is cancelled must call it
/// (dropping the stream cancels it too); `EventStreamRunner` does so for every reconnect.
public struct EventConnection: Sendable {
  public var events: AsyncThrowingStream<ServerEvent, any Error>
  public var close: @Sendable () -> Void

  public init(events: AsyncThrowingStream<ServerEvent, any Error>, close: @escaping @Sendable () -> Void) {
    self.events = events
    self.close = close
  }
}

/// One long-lived SSE connection to `/api/event`.
///
/// The stream throws on disconnect (a typed client error, or `EventStreamOverflow` when the consumer
/// fell behind); the caller owns the reconnect-and-rehydrate loop, and `EventStreamRunner` is that
/// loop. REST remains authoritative: these events only invalidate and project.
public struct EventStream: Sendable {
  public var transport: HTTPTransport
  public var clock: ClockClient
  /// How many decoded events may wait for the consumer before the connection is failed.
  public var capacity: Int
  /// The whole open — connect, request, and response headers — must finish by then. A server that
  /// accepts the socket but withholds its headers is as useless as one that refuses the connection.
  /// Nil disables the deadline (a caller that owns its own timeout).
  public var connectDeadline: Duration?
  /// A stream silent this long (three missed 15 s heartbeats) is stranded.
  public var idleDeadline: Duration
  /// A caller that owns its own lifetime can opt out; the app uses the watchdog.
  public var enabledWatchdog: Bool

  public static let defaultConnectDeadline: Duration = .milliseconds(4500)
  public static let defaultIdleDeadline: Duration = .seconds(45)

  public init(
    transport: HTTPTransport,
    clock: ClockClient,
    capacity: Int = 128,
    connectDeadline: Duration? = EventStream.defaultConnectDeadline,
    idleDeadline: Duration = EventStream.defaultIdleDeadline,
    enabledWatchdog: Bool = true
  ) {
    self.transport = transport
    self.clock = clock
    self.capacity = capacity
    self.connectDeadline = connectDeadline
    self.idleDeadline = idleDeadline
    self.enabledWatchdog = enabledWatchdog
  }

  /// Opens one connection. Throws when it cannot open (including when the headers miss
  /// `connectDeadline`); the returned connection ends with an error when the stream drops.
  public func connect(server: OpenCodeServer) async throws -> EventConnection {
    guard let url = server.endpoint(path: "/api/event") else {
      throw OpenCodeClientError(.invalidURL)
    }
    let request = HTTPRequest(
      url: url,
      headers: [
        "Accept": "text/event-stream",
        "X-OpenCode-Capabilities": "experimental-media-uri",
        "X-OpenCode-Op": UUID().uuidString,
        "X-OpenCode-Req": UUID().uuidString,
      ],
      authorization: server.basicAuthorization,
      // The audited stream reads with a 90 s idle interval; heartbeats reset it.
      timeout: 90,
      redirectPolicy: .followSameOrigin
    )

    let response: HTTPStream
    do {
      response = try await Self.openWithDeadline(
        transport: transport,
        request: request,
        deadline: connectDeadline,
        clock: clock
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as OpenCodeClientError {
      throw error
    } catch {
      throw Self.clientError(for: error)
    }

    // A rejected answer is a closed connection, not an open stream nobody reads.
    if response.status == 401 {
      response.close()
      throw OpenCodeClientError(.status(401))
    }
    guard (200...299).contains(response.status) else {
      response.close()
      throw OpenCodeClientError(.status(response.status), isLocationMissing: false)
    }

    let batcher = EventBatcher(
      configuration: .init(capacity: capacity),
      clock: clock
    )
    let activity = StreamActivity(start: clock.now())
    let lifecycle = ConnectionLifecycle()
    let clock = clock

    lifecycle.onClose { response.close() }

    let readTask = Task {
      var parser = SSEParser()
      do {
        for try await chunk in response.chunks {
          activity.note(clock.now())
          for frame in try parser.feed(chunk) {
            try await Self.deliver(frame, to: batcher)
          }
        }
        for frame in try parser.finish() {
          try await Self.deliver(frame, to: batcher)
        }
        await batcher.fail(OpenCodeClientError(.streamEnded))
      } catch is CancellationError {
        await batcher.finish()
      } catch let error as OpenCodeClientError {
        await batcher.fail(error)
      } catch let error as SSEError {
        await batcher.fail(Self.clientError(for: error))
      } catch {
        await batcher.fail(Self.clientError(for: error))
      }
    }
    lifecycle.onClose { readTask.cancel() }

    if enabledWatchdog {
      let idleDeadline = idleDeadline
      let watchdog = Task {
        while !Task.isCancelled {
          let elapsed = clock.now() - activity.start
          let remaining = idleDeadline - (activity.last.map { elapsed - $0 } ?? elapsed)
          if remaining <= .zero {
            await batcher.fail(OpenCodeClientError(.transport(.timedOut)))
            lifecycle.close()
            return
          }
          do {
            try await clock.sleep(remaining)
          } catch {
            return
          }
        }
      }
      lifecycle.onClose { watchdog.cancel() }
    }

    await batcher.setCloseHandler {
      lifecycle.close()
    }

    let events = await batcher.events
    return EventConnection(
      events: events,
      close: {
        lifecycle.close()
        Task { await batcher.cancel() }
      }
    )
  }

  /// `transport.open`, unless the whole open (including headers) misses `deadline`.
  static func openWithDeadline(
    transport: HTTPTransport,
    request: HTTPRequest,
    deadline: Duration?,
    clock: ClockClient
  ) async throws -> HTTPStream {
    guard let deadline else {
      return try await transport.open(request)
    }
    return try await withThrowingTaskGroup(of: HTTPStream.self) { group in
      group.addTask {
        let stream = try await transport.open(request)
        // The deadline won between the response arriving and this task being cancelled: a stream
        // nobody will read must not keep a session or socket alive.
        if Task.isCancelled {
          stream.close()
          throw CancellationError()
        }
        return stream
      }
      group.addTask {
        try await clock.sleep(deadline)
        throw OpenCodeClientError(.transport(.timedOut))
      }
      defer { group.cancelAll() }
      guard let first = try await group.next() else {
        throw OpenCodeClientError(.transport(.timedOut))
      }
      return first
    }
  }

  private static func deliver(_ frame: SSEFrame, to batcher: EventBatcher) async throws {
    guard let event = try ServerEventDecoder.decode(frame.data) else { return }
    await batcher.receive(event)
  }

  static func clientError(for error: any Error) -> OpenCodeClientError {
    if let error = error as? OpenCodeClientError { return error }
    if error is SSEError { return OpenCodeClientError(.streamOversizedFrame) }
    if error is ServerEventError { return OpenCodeClientError(.streamServerFailure) }
    if error is EventStreamOverflow { return OpenCodeClientError(.streamOverflow) }
    if let failure = TransportFailure(error) { return OpenCodeClientError(.transport(failure)) }
    return OpenCodeClientError(.unreachable)
  }
}

/// The last line seen on one connection, so the watchdog can tell a quiet stream from a dead one.
private final class StreamActivity: Sendable {
  let start: Duration
  private let lastLine = Mutex<Duration?>(nil)

  init(start: Duration) {
    self.start = start
  }

  var last: Duration? {
    lastLine.withLock { $0 }
  }

  func note(_ now: Duration) {
    lastLine.withLock { $0 = now - start }
  }
}

/// Runs the close handlers exactly once, from whichever path gets there first.
private final class ConnectionLifecycle: Sendable {
  private struct State {
    var closed = false
    var handlers: [@Sendable () -> Void] = []
  }

  private let state = Mutex(State())

  func onClose(_ handler: @escaping @Sendable () -> Void) {
    let runNow = state.withLock { state -> Bool in
      if state.closed { return true }
      state.handlers.append(handler)
      return false
    }
    if runNow { handler() }
  }

  var isClosed: Bool {
    state.withLock { $0.closed }
  }

  func close() {
    let handlers = state.withLock { state -> [@Sendable () -> Void] in
      guard !state.closed else { return [] }
      state.closed = true
      let handlers = state.handlers
      state.handlers.removeAll()
      return handlers
    }
    for handler in handlers {
      handler()
    }
  }
}

/// Reconnects an `EventStream`, resynchronizing from REST between attempts.
///
/// A single 401 ends the loop: the credentials are wrong, and retrying only hammers the server.
/// A consumer that falls behind ends its connection with `EventStreamOverflow`; the runner closes
/// it, calls `onResynchronize` (where a feature reads authoritative REST state), and reconnects on
/// the overflow schedule. Consecutive overflows are bounded: once the limit is passed the stream
/// ends with the overflow instead of spinning.
public struct EventStreamRunner: Sendable {
  public var clock: ClockClient
  /// Opens one connection. Split from `EventStream` so a test can script the exact failures a real
  /// connection produces (overflow, rejected open, dropped socket).
  public var connect: @Sendable (OpenCodeServer) async throws -> EventConnection
  public var policy: RetryPolicy
  public var overflowPolicy: RetryPolicy
  public var environment: RetryEnvironment
  /// How many events may wait for the consumer across reconnects.
  public var capacity: Int
  /// Called once per overflow, before the reconnect, and never after the stream ends. This is the
  /// explicit REST-resynchronization signal: events are a projection, REST is authoritative.
  public var onResynchronize: @Sendable (EventStreamOverflow) async -> Void
  /// A connection that overflows this many times in a row is abandoned rather than retried forever.
  public var maximumConsecutiveOverflows: Int

  public init(
    stream: EventStream,
    policy: RetryPolicy = .stream,
    overflowPolicy: RetryPolicy = .streamOverflow,
    environment: RetryEnvironment = .live,
    capacity: Int = 128,
    maximumConsecutiveOverflows: Int = 5,
    onResynchronize: @escaping @Sendable (EventStreamOverflow) async -> Void = { _ in }
  ) {
    self.clock = stream.clock
    self.connect = { server in try await stream.connect(server: server) }
    self.policy = policy
    self.overflowPolicy = overflowPolicy
    self.environment = environment
    self.capacity = capacity
    self.maximumConsecutiveOverflows = maximumConsecutiveOverflows
    self.onResynchronize = onResynchronize
  }

  public init(
    clock: ClockClient,
    connect: @escaping @Sendable (OpenCodeServer) async throws -> EventConnection,
    policy: RetryPolicy = .stream,
    overflowPolicy: RetryPolicy = .streamOverflow,
    environment: RetryEnvironment = .live,
    capacity: Int = 128,
    maximumConsecutiveOverflows: Int = 5,
    onResynchronize: @escaping @Sendable (EventStreamOverflow) async -> Void = { _ in }
  ) {
    self.clock = clock
    self.connect = connect
    self.policy = policy
    self.overflowPolicy = overflowPolicy
    self.environment = environment
    self.capacity = capacity
    self.maximumConsecutiveOverflows = maximumConsecutiveOverflows
    self.onResynchronize = onResynchronize
  }

  public func events(server: OpenCodeServer) -> AsyncThrowingStream<ServerEvent, any Error> {
    let channel = BoundedChannel<ServerEvent>(capacity: capacity)
    let log = AppLog(category: .stream)
    let clock = clock
    let connect = connect
    let policy = policy
    let overflowPolicy = overflowPolicy
    let environment = environment
    let onResynchronize = onResynchronize
    let maximumConsecutiveOverflows = max(1, maximumConsecutiveOverflows)

    let task = Task {
      var schedule = RetrySchedule(policy: policy, clock: clock, environment: environment)
      var overflowSchedule = RetrySchedule(
        policy: overflowPolicy,
        clock: clock,
        environment: environment
      )
      var consecutiveOverflows = 0

      while !Task.isCancelled {
        var connection: EventConnection?
        defer { connection?.close() }

        do {
          let opened = try await connect(server)
          connection = opened
          log.event(.streamConnected)
          for try await event in opened.events {
            if case .connected = event {
              schedule.reset()
              overflowSchedule.reset()
              consecutiveOverflows = 0
            }
            switch channel.push(event) {
            case .accepted:
              continue
            case .overflow:
              throw EventStreamOverflow()
            case .closed:
              return
            }
          }
          // The connection ended without an error the batcher could report.
          log.event(.streamDisconnected)
          guard try await waitForRetry(OpenCodeClientError(.streamEnded), schedule: &schedule) else {
            channel.fail(OpenCodeClientError(.streamEnded))
            return
          }
        } catch is CancellationError {
          return
        } catch let overflow as EventStreamOverflow {
          consecutiveOverflows += 1
          log.event(
            .streamOverflow,
            [LogField("consecutive", .count(consecutiveOverflows))]
          )
          if consecutiveOverflows > maximumConsecutiveOverflows {
            channel.fail(overflow)
            return
          }
          await onResynchronize(overflow)
          log.event(.streamResynchronized)
          guard try await waitForRetry(OpenCodeClientError(.streamOverflow), schedule: &overflowSchedule)
          else {
            channel.fail(overflow)
            return
          }
        } catch let error as OpenCodeClientError {
          log.event(.streamDisconnected, [LogField("status", .status(error.statusCode ?? 0))])
          guard try await waitForRetry(error, schedule: &schedule) else {
            channel.fail(error)
            return
          }
        } catch {
          let wrapped = EventStream.clientError(for: error)
          guard try await waitForRetry(wrapped, schedule: &schedule) else {
            channel.fail(wrapped)
            return
          }
        }
      }
    }
    channel.setCloseHandler {
      task.cancel()
    }
    return channel.stream
  }

  /// True to try again; false when the loop must end (a 401, or the schedule gave up).
  private func waitForRetry(
    _ error: OpenCodeClientError,
    schedule: inout RetrySchedule
  ) async throws -> Bool {
    if error.statusCode == 401 { return false }
    guard let pause = schedule.next(error.retryVerdict(idempotency: .idempotent)) else {
      return false
    }
    _ = try await pause.run()
    return true
  }
}
