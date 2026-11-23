import Foundation
import OpenCodeCore
import OpenCodeServer
import Synchronization
import Testing

@Suite("Session wait loop")
struct SessionWaitLoopTests {
  private final class Script: Sendable {
    private let state = Mutex<(failures: Int, active: Bool, waits: Int)>((
      failures: 0, active: true, waits: 0
    ))

    var failures: Int { state.withLock { $0.failures } }
    func setActive(_ value: Bool) { state.withLock { $0.active = value } }
    func wait() throws {
      let remaining = state.withLock { value -> Int in
        value.waits += 1
        defer { value.failures = max(0, value.failures - 1) }
        return value.failures
      }
      if remaining > 0 { throw OpenCodeClientError(.status(504)) }
    }
    func fail(_ count: Int) { state.withLock { $0.failures = count } }
    func isActive() throws -> Bool { state.withLock { $0.active } }
  }

  @Test("a long poll that ran out on a live run re-arms without a backoff")
  func longPollRearmsImmediately() async throws {
    let clock = ClockClient.manual()
    let polls = WaitCounter()
    try await SessionWaitLoop.run(
      clock: clock.client,
      wait: {
        polls.increment()
        if polls.count == 1 {
          clock.advance(by: .seconds(21))
          throw OpenCodeClientError(.status(504))
        }
      },
      isActive: { true }
    )
    #expect(polls.count == 2)
  }

  @Test("a fast failure checks the run, then waits before retrying")
  func fastFailureChecksRunAndBacksOff() async throws {
    let clock = ClockClient.recording()
    let script = Script()
    script.fail(1)
    try await SessionWaitLoop.run(
      clock: clock.client,
      wait: { try script.wait() },
      isActive: { try script.isActive() },
      unit: { 0 }
    )
    #expect(clock.sleeps == [Duration.milliseconds(500)])
  }

  @Test("a finished run ends the wait without another poll")
  func inactiveRunEndsWait() async throws {
    let clock = ClockClient.recording()
    let script = Script()
    script.fail(1)
    script.setActive(false)
    try await SessionWaitLoop.run(
      clock: clock.client,
      wait: { try script.wait() },
      isActive: { try script.isActive() }
    )
    #expect(clock.sleeps.isEmpty)
  }

  @Test("a caller that owns retries gets its fast failure back after the active check")
  func callerOwnedRetries() async throws {
    let clock = ClockClient.recording()
    let script = Script()
    script.fail(1)
    let checked = WaitCounter()
    await #expect(throws: OpenCodeClientError.self) {
      try await SessionWaitLoop.run(
        clock: clock.client,
        wait: { try script.wait() },
        isActive: {
          checked.increment()
          return try script.isActive()
        },
        callerOwnsRetries: true
      )
    }
    #expect(checked.count == 1)
    #expect(clock.sleeps.isEmpty)
  }

  @Test("fast failures stop at twelve")
  func boundedFastFailures() async throws {
    let clock = ClockClient.recording()
    let script = Script()
    script.fail(20)
    let polls = WaitCounter()
    await #expect(throws: OpenCodeClientError.self) {
      try await SessionWaitLoop.run(
        clock: clock.client,
        wait: {
          polls.increment()
          try script.wait()
        },
        isActive: { try script.isActive() }
      )
    }
    #expect(polls.count == SessionWaitLoop.maximumFastFailures)
    #expect(clock.sleeps.count == SessionWaitLoop.maximumFastFailures - 1)
  }
}


private final class WaitCounter: Sendable {
  private let value = Mutex(0)
  func increment() { value.withLock { $0 += 1 } }
  var count: Int { value.withLock { $0 } }
}
