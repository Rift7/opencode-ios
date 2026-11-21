import Foundation
import OpenCodeCore
import OpenCodeServer
import Synchronization
import Testing

@Suite("Retry policy")
struct RetryPolicyTests {
  @Test("equal jitter stays between half the ceiling and the ceiling")
  func jitter() {
    let ceiling = Duration.seconds(8)
    #expect(RetryPolicy.jitter(ceiling: ceiling, unit: 0) == .seconds(4))
    #expect(RetryPolicy.jitter(ceiling: ceiling, unit: 1) == .seconds(8))
    #expect(RetryPolicy.jitter(ceiling: ceiling, unit: 2) == .seconds(8))
    #expect(RetryPolicy.jitter(ceiling: ceiling, unit: -1) == .seconds(4))
  }

  @Test("the ceiling doubles from the base and stops at the maximum")
  func ceiling() {
    let policy = RetryPolicy(
      maxAttempts: 5, baseDelay: .seconds(1), maxDelay: .seconds(8), retryWindow: nil
    )
    #expect(policy.ceiling(1) == .seconds(1))
    #expect(policy.ceiling(2) == .seconds(2))
    #expect(policy.ceiling(3) == .seconds(4))
    #expect(policy.ceiling(4) == .seconds(8))
    #expect(policy.ceiling(5) == .seconds(8))
    #expect(policy.ceiling(0) == .zero)
  }

  @Test("the request policy stops after five attempts within its window")
  func requestPolicyStops() {
    var backoff = RetryBackoff(policy: .request)
    var elapsed = Duration.zero
    var attempts = 0
    while true {
      attempts += 1
      guard case .retry(let delay) = backoff.decide(
        verdict: .transient(retryAfter: nil), elapsed: elapsed, offline: false, unit: 0.5
      ) else { break }
      elapsed += delay
    }
    #expect(attempts == 5)
    #expect(elapsed <= RetryPolicy.request.retryWindow!)
  }

  @Test("a Retry-After beyond the policy ceiling gives up instead of waiting it out")
  func retryAfterBeyondLimitGivesUp() {
    var backoff = RetryBackoff(policy: .request)
    #expect(
      backoff.decide(
        verdict: .transient(retryAfter: .seconds(31)), elapsed: .zero, offline: false, unit: 0.5
      ) == .giveUp
    )
  }

  @Test("a Retry-After longer than the jitter is the wait")
  func retryAfterWins() {
    var backoff = RetryBackoff(policy: .request)
    #expect(
      backoff.decide(
        verdict: .transient(retryAfter: .seconds(5)), elapsed: .zero, offline: false, unit: 0
      ) == .retry(after: .seconds(5))
    )
  }

  @Test("offline waits for a network path instead of spending attempts")
  func offlineWaits() {
    var backoff = RetryBackoff(policy: .request)
    #expect(
      backoff.decide(verdict: .transient(retryAfter: nil), elapsed: .zero, offline: true, unit: 0.5)
        == .waitForNetwork(upTo: .seconds(30))
    )
    #expect(backoff.failures == 0)
  }

  @Test("the stream policy stays fast for 15 s, then backs off to five minutes")
  func streamFastWindow() {
    var backoff = RetryBackoff(policy: .stream)
    var elapsed = Duration.zero
    var delays: [Duration] = []
    for _ in 0..<6 {
      guard case .retry(let delay) = backoff.decide(
        verdict: .transient(retryAfter: nil), elapsed: elapsed, offline: false, unit: 1
      ) else { break }
      delays.append(delay)
      elapsed += delay
    }
    // Within the fast window every wait is at most 2 s.
    #expect(delays.prefix(3).allSatisfy { $0 <= .seconds(2) })
    #expect(delays.last! <= .seconds(300))
  }

  @Test("classification: reads retry an interrupted connection, writes do not")
  func classification() {
    let interrupted = OpenCodeClientError(.transport(.interrupted))
    #expect(interrupted.retryVerdict(idempotency: .idempotent) == .transient(retryAfter: nil))
    #expect(interrupted.retryVerdict(idempotency: .unsafe) == .permanent)

    let notSent = OpenCodeClientError(.transport(.notSent))
    #expect(notSent.retryVerdict(idempotency: .unsafe) == .transient(retryAfter: nil))

    let timedOut = OpenCodeClientError(.transport(.timedOut))
    #expect(timedOut.retryVerdict(idempotency: .unsafe) == .permanent)
  }

  @Test("classification: only 408, 429, 503 and gateway failures are transient")
  func statusClassification() {
    #expect(OpenCodeClientError(.status(408)).retryVerdict(idempotency: .unsafe) == .transient(retryAfter: nil))
    #expect(OpenCodeClientError(.status(429)).retryVerdict(idempotency: .unsafe) == .transient(retryAfter: nil))
    #expect(OpenCodeClientError(.status(503)).retryVerdict(idempotency: .unsafe) == .transient(retryAfter: nil))
    #expect(OpenCodeClientError(.status(502)).retryVerdict(idempotency: .idempotent) == .transient(retryAfter: nil))
    #expect(OpenCodeClientError(.status(502)).retryVerdict(idempotency: .unsafe) == .permanent)
    #expect(OpenCodeClientError(.status(520)).retryVerdict(idempotency: .idempotent) == .transient(retryAfter: nil))
    #expect(OpenCodeClientError(.status(500)).retryVerdict(idempotency: .idempotent) == .permanent)
    #expect(OpenCodeClientError(.status(401)).retryVerdict(idempotency: .idempotent) == .permanent)
    #expect(OpenCodeClientError(.status(404)).retryVerdict(idempotency: .idempotent) == .permanent)
    #expect(OpenCodeClientError(.unsupported).retryVerdict(idempotency: .idempotent) == .permanent)
  }

  @Test("may-have-arrived is only true once the request could have reached the server")
  func mayHaveArrived() {
    #expect(!OpenCodeClientError(.transport(.notSent)).mayHaveReachedServer)
    #expect(OpenCodeClientError(.transport(.interrupted)).mayHaveReachedServer)
    #expect(OpenCodeClientError(.transport(.timedOut)).mayHaveReachedServer)
    #expect(OpenCodeClientError(.status(502)).mayHaveReachedServer)
    #expect(!OpenCodeClientError(.status(401)).mayHaveReachedServer)
    var earlier = OpenCodeClientError(.status(400))
    earlier.earlierAttemptMayHaveArrived = true
    #expect(earlier.mayHaveReachedServer)
  }

  @Test("Retry-After reads seconds or an HTTP date and never goes negative")
  func retryAfterParsing() {
    #expect(OpenCodeClientError.retryAfter(header: "3") == .seconds(3))
    #expect(OpenCodeClientError.retryAfter(header: "-4") == .seconds(0))
    #expect(OpenCodeClientError.retryAfter(header: "  ") == nil)
    #expect(OpenCodeClientError.retryAfter(header: "soon") == nil)

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let date = "Tue, 14 Nov 2023 22:13:30 GMT"
    #expect(OpenCodeClientError.retryAfter(header: date, now: now) == .seconds(10))
  }

  @Test("the log summary carries status and transport, never a message")
  func logSummary() {
    let error = OpenCodeClientError(
      .status(503), retryAfter: .seconds(2), attempts: 3, earlierAttemptMayHaveArrived: true
    )
    #expect(error.logSummary == "HTTP 503, after 3 attempts")
    #expect(!error.logSummary.contains("box"))
  }
}

@Suite("Retry loop")
struct NetworkRetryTests {
  @Test("a transient failure is retried with the recorded schedule")
  func retriesTransientFailure() async throws {
    let clock = ClockClient.recording()
    let counter = Counter()
    let value = try await NetworkRetry.run(
      policy: .request,
      idempotency: .idempotent,
      clock: clock.client,
      environment: .online(unit: 0)
    ) { attempt in
      if attempt < 3 { throw OpenCodeClientError(.status(503)) }
      counter.increment()
      return "ok"
    }
    #expect(value == "ok")
    #expect(counter.value == 1)
    #expect(clock.sleeps.count == 2)
  }

  @Test("an unsafe write is not resent after an interrupted connection")
  func unsafeWriteIsNotResent() async throws {
    let clock = ClockClient.recording()
    let counter = Counter()
    await #expect(throws: OpenCodeClientError.self) {
      try await NetworkRetry.run(
        policy: .request,
        idempotency: .unsafe,
        clock: clock.client,
        environment: .online(unit: 0)
      ) { _ in
        counter.increment()
        throw OpenCodeClientError(.transport(.interrupted))
      }
    }
    #expect(counter.value == 1)
    #expect(clock.sleeps.isEmpty)
  }

  @Test("an unsafe write that was never sent is retried")
  func unsafeWriteRetriesWhenNotSent() async throws {
    let clock = ClockClient.recording()
    let counter = Counter()
    let value = try await NetworkRetry.run(
      policy: .request,
      idempotency: .unsafe,
      clock: clock.client,
      environment: .online(unit: 0)
    ) { attempt in
      if attempt == 1 { throw OpenCodeClientError(.transport(.notSent)) }
      counter.increment()
      return 1
    }
    #expect(value == 1)
    #expect(counter.value == 1)
  }

  @Test("the last attempt's error carries the count and the ambiguity flag")
  func finalErrorDescribesTheRun() async throws {
    let clock = ClockClient.recording()
    do {
      try await NetworkRetry.run(
        policy: .request,
        idempotency: .idempotent,
        clock: clock.client,
        environment: .online(unit: 0)
      ) { _ in
        throw OpenCodeClientError(.transport(.interrupted))
      }
      Issue.record("expected a failure")
    } catch let error as OpenCodeClientError {
      #expect(error.attempts == 5)
      #expect(error.earlierAttemptMayHaveArrived)
    }
  }

  @Test("cancellation is not retried and never surfaces as a reachability failure")
  func cancellationStops() async throws {
    let clock = ClockClient.gate()
    let counter = Counter()
    let task = Task {
      try await NetworkRetry.run(
        policy: .request,
        idempotency: .idempotent,
        clock: clock.client,
        environment: .online(unit: 0)
      ) { _ in
        counter.increment()
        throw OpenCodeClientError(.transport(.interrupted))
      }
    }
    // Let the first attempt fail and the loop wait.
    while clock.pendingCount == 0 { await Task.yield() }
    task.cancel()
    let result = await task.result
    #expect(throws: CancellationError.self) { try result.get() }
    #expect(counter.value == 1)
  }

  @Test("one-attempt policy sends once and hands the error back")
  func oncePolicy() async throws {
    let counter = Counter()
    let clock = ClockClient.recording()
    await #expect(throws: OpenCodeClientError.self) {
      try await NetworkRetry.run(
        policy: .once,
        idempotency: .idempotent,
        clock: clock.client,
        environment: .online(unit: 0)
      ) { _ in
        counter.increment()
        throw OpenCodeClientError(.status(503))
      }
    }
    #expect(counter.value == 1)
    #expect(clock.sleeps.isEmpty)
  }
}

/// A small thread-safe counter for the scripted operations above.
final class Counter: Sendable {
  private let state = Mutex(0)

  var value: Int {
    state.withLock { $0 }
  }

  func increment() {
    state.withLock { $0 += 1 }
  }
}
