import Foundation
import OpenCodeCore
import OpenCodeServer
import Synchronization
import Testing

@Suite("Event stream phases")
struct EventStreamPhaseTests {
  private let server = OpenCodeServer(url: "http://127.0.0.1:4110", password: "token")

  private final class PhaseLog: Sendable {
    private let phases = Mutex<[EventStreamPhase]>([])

    func record(_ phase: EventStreamPhase) {
      phases.withLock { $0.append(phase) }
    }

    var values: [EventStreamPhase] {
      phases.withLock { $0 }
    }
  }

  private func connection(
    _ events: [ServerEvent],
    then error: (any Error)? = nil
  ) -> EventConnection {
    let (stream, continuation) = AsyncThrowingStream<ServerEvent, any Error>.makeStream()
    Task {
      for event in events {
        continuation.yield(event)
      }
      if let error {
        continuation.finish(throwing: error)
      } else {
        continuation.finish()
      }
    }
    return EventConnection(events: stream, close: {})
  }

  @Test("a closed connection reports disconnecting and then ended")
  func closedConnectionPhases() async {
    let log = PhaseLog()
    let runner = EventStreamRunner(
      clock: .testValue,
      connect: { _ in self.connection([.connected]) },
      policy: .once,
      environment: .online(unit: 0),
      onPhase: { log.record($0) }
    )

    do {
      for try await _ in runner.events(server: server) {}
    } catch {
      // The loop ends after one attempt under the once policy.
    }

    let phases = log.values
    #expect(phases.first == .connected)
    #expect(phases.contains(.disconnected(OpenCodeClientError(.streamEnded))))
    #expect(phases.last == .ended(OpenCodeClientError(.streamEnded)))
  }

  @Test("a 401 reports a final ended phase without a retry")
  func rejectedConnectionPhases() async {
    let log = PhaseLog()
    let attempts = Mutex(0)
    let runner = EventStreamRunner(
      clock: .testValue,
      connect: { _ in
        attempts.withLock { $0 += 1 }
        throw OpenCodeClientError(.status(401))
      },
      policy: .stream,
      environment: .online(unit: 0),
      onPhase: { log.record($0) }
    )

    do {
      for try await _ in runner.events(server: server) {}
    } catch {
      // Expected: the server rejected the credentials.
    }

    #expect(attempts.withLock { $0 } == 1)
    #expect(log.values == [
      .disconnected(OpenCodeClientError(.status(401))),
      .ended(OpenCodeClientError(.status(401))),
    ])
  }

  @Test("an overflow reports resynchronizing before the next connection")
  func overflowPhaseOrder() async throws {
    let log = PhaseLog()
    let attempts = Mutex(0)
    let runner = EventStreamRunner(
      clock: .testValue,
      connect: { _ in
        let attempt = attempts.withLock { value -> Int in
          value += 1
          return value
        }
        if attempt == 1 {
          return self.connection([.connected], then: EventStreamOverflow())
        }
        return self.connection([.connected])
      },
      environment: .online(unit: 0),
      onPhase: { log.record($0) }
    )

    var received = 0
    for try await event in runner.events(server: server) {
      if event == .connected { received += 1 }
      if received == 2 { break }
    }

    let phases = log.values
    #expect(Array(phases.prefix(3)) == [.connected, .resynchronizing, .connected])
  }
}
