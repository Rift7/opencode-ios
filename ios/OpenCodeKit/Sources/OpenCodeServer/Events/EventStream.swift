import Foundation
import OpenCodeCore
import Synchronization

/// One long-lived SSE connection to `/api/event`.
///
/// The stream throws on disconnect (a typed client error, or `EventStreamOverflow` when the consumer
/// fell 128 events behind); the caller owns the reconnect-and-rehydrate loop, and `EventStreamRunner`
/// is that loop. REST remains authoritative: these events only invalidate and project.
public struct EventStream: Sendable {
  public var transport: HTTPTransport
  public var clock: ClockClient
  /// How many decoded events may wait for the consumer before the connection is failed.
  public var capacity: Int
  /// A stream that has not opened by then is stranded on a dead route.
  public var connectDeadline: Duration
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
    connectDeadline: Duration = EventStream.defaultConnectDeadline,
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

  /// Opens one connection. Throws when it cannot open; the returned stream ends with an error when
  /// the connection drops.
  public func connect(server: OpenCodeServer) async throws -> AsyncThrowingStream<ServerEvent, any Error> {
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
      response = try await transport.open(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as OpenCodeClientError {
      throw error
    } catch {
      throw Self.clientError(for: error)
    }

    if response.status == 401 {
      throw OpenCodeClientError(.status(401))
    }
    guard (200...299).contains(response.status) else {
      throw OpenCodeClientError(.status(response.status), isLocationMissing: false)
    }

    let batcher = EventBatcher(
      configuration: .init(capacity: capacity),
      clock: clock
    )
    let activity = StreamActivity(start: clock.now())
    let clock = clock

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

    let connectDeadline = connectDeadline
    let idleDeadline = idleDeadline
    let watchdog: Task<Void, Never>? = enabledWatchdog ? Task {
      do {
        try await clock.sleep(connectDeadline)
        while !Task.isCancelled {
          guard let last = activity.last else {
            await batcher.fail(OpenCodeClientError(.transport(.timedOut)))
            readTask.cancel()
            return
          }
          let remaining = idleDeadline - (clock.now() - activity.start - last)
          if remaining <= .zero {
            await batcher.fail(OpenCodeClientError(.transport(.timedOut)))
            readTask.cancel()
            return
          }
          try await clock.sleep(remaining)
        }
      } catch {
        return
      }
    } : nil

    await batcher.setCloseHandler {
      readTask.cancel()
      watchdog?.cancel()
    }

    return await batcher.events
  }

  private static func deliver(_ frame: SSEFrame, to batcher: EventBatcher) async throws {
    guard let event = try ServerEventDecoder.decode(frame.data) else { return }
    await batcher.receive(event)
  }

  static func clientError(for error: any Error) -> OpenCodeClientError {
    if let error = error as? OpenCodeClientError { return error }
    if error is SSEError { return OpenCodeClientError(.streamOversizedFrame) }
    if error is ServerEventError { return OpenCodeClientError(.streamServerFailure) }
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

/// Reconnects an `EventStream`, hydrating between attempts. A single 401 ends the loop: the
/// credentials are wrong, and retrying only hammers the server.
///
/// Events cross a bounded channel, so a consumer that stalls fails the connection with
/// `EventStreamOverflow` and rehydrates from REST rather than growing memory.
public struct EventStreamRunner: Sendable {
  public var stream: EventStream
  public var policy: RetryPolicy
  public var environment: RetryEnvironment
  /// How many events may wait for the consumer across reconnects.
  public var capacity: Int

  public init(
    stream: EventStream,
    policy: RetryPolicy = .stream,
    environment: RetryEnvironment = .live,
    capacity: Int = 128
  ) {
    self.stream = stream
    self.policy = policy
    self.environment = environment
    self.capacity = capacity
  }

  public func events(server: OpenCodeServer) -> AsyncThrowingStream<ServerEvent, any Error> {
    let channel = BoundedChannel<ServerEvent>(capacity: capacity)
    let log = AppLog(category: .stream)
    let task = Task {
      var schedule = RetrySchedule(policy: policy, clock: stream.clock, environment: environment)
      while !Task.isCancelled {
        do {
          let connection = try await stream.connect(server: server)
          log.event(.streamConnected)
          for try await event in connection {
            if case .connected = event {
              schedule.reset()
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
        } catch let error as EventStreamOverflow {
          log.event(.streamOverflow)
          guard try await waitForRetry(OpenCodeClientError(.unreachable), schedule: &schedule) else {
            channel.fail(error)
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
