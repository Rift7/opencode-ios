import Foundation
import OpenCodeCore

/// What a retry loop needs from the world, so tests can script it.
public struct RetryEnvironment: Sendable {
  /// A random value in 0..<1.
  public var random: @Sendable () -> Double
  /// True only when the phone is known to have no network path.
  public var isOffline: @Sendable () -> Bool
  /// Returns once a network path is available (or at once if one is).
  public var networkAvailable: @Sendable () async -> Void

  public init(
    random: @escaping @Sendable () -> Double,
    isOffline: @escaping @Sendable () -> Bool,
    networkAvailable: @escaping @Sendable () async -> Void
  ) {
    self.random = random
    self.isOffline = isOffline
    self.networkAvailable = networkAvailable
  }

  /// Always online, with jitter fixed at `unit`.
  public static func online(unit: Double = 0.5) -> RetryEnvironment {
    RetryEnvironment(random: { unit }, isOffline: { false }, networkAvailable: {})
  }

  /// The app's default until the connection shell observes the path (phase 5): a retry follows its
  /// schedule instead of waiting on a network signal nothing produces yet.
  public static let live = RetryEnvironment.online()
}

/// One retry loop's schedule: a `RetryBackoff` with a clock and the world.
public struct RetrySchedule: Sendable {
  public private(set) var failures = 0
  public private(set) var backoff: RetryBackoff
  private let clock: ClockClient
  private let environment: RetryEnvironment
  private var firstFailureAt: Duration?

  public init(policy: RetryPolicy, clock: ClockClient, environment: RetryEnvironment) {
    self.backoff = RetryBackoff(policy: policy)
    self.clock = clock
    self.environment = environment
  }

  /// The pause before the next attempt, or nil to stop trying.
  public mutating func next(_ verdict: RetryVerdict) -> RetryPause? {
    let elapsed = elapsedSinceFirstFailure()
    let decision = backoff.decide(
      verdict: verdict,
      elapsed: elapsed,
      offline: backoff.policy.waitsForNetwork && environment.isOffline(),
      unit: environment.random()
    )
    failures = backoff.failures
    switch decision {
    case .giveUp:
      return nil
    case .retry(let delay):
      return RetryPause(kind: .sleep(delay), clock: clock, environment: environment)
    case .waitForNetwork(let limit):
      return RetryPause(kind: .network(limit), clock: clock, environment: environment)
    }
  }

  /// True to try again at once, with no pause, while the window lasts.
  public mutating func retryNow(_ verdict: RetryVerdict) -> Bool {
    let elapsed = elapsedSinceFirstFailure()
    let result = backoff.decideNow(verdict: verdict, elapsed: elapsed)
    failures = backoff.failures
    return result
  }

  /// A connection that held: the next failure starts the schedule over.
  public mutating func reset() {
    backoff.reset()
    firstFailureAt = nil
    failures = 0
  }

  private mutating func elapsedSinceFirstFailure() -> Duration {
    if let firstFailureAt {
      return clock.now() - firstFailureAt
    }
    firstFailureAt = clock.now()
    return .zero
  }
}

/// The wait between two attempts.
public struct RetryPause: Sendable {
  public enum Kind: Sendable, Equatable {
    case sleep(Duration)
    case network(Duration?)
  }

  public let kind: Kind
  private let clock: ClockClient
  private let environment: RetryEnvironment

  init(kind: Kind, clock: ClockClient, environment: RetryEnvironment) {
    self.kind = kind
    self.clock = clock
    self.environment = environment
  }

  /// Waits it out. Cancellation propagates; `reachable` ends a sleep early when the server answers.
  /// Returns false if the network did not come back in time.
  public func run(reachable: (@Sendable () async -> Void)? = nil) async throws -> Bool {
    switch kind {
    case .sleep(let delay):
      if delay <= .zero {
        try Task.checkCancellation()
        return true
      }
      if let reachable {
        await Self.firstToFinish(
          { try? await clock.sleep(delay) },
          reachable
        )
      } else {
        try await clock.sleep(delay)
      }
      try Task.checkCancellation()
      return true
    case .network(let limit):
      if let limit {
        await Self.firstToFinish({ try? await clock.sleep(limit) }, environment.networkAvailable)
      } else {
        await environment.networkAvailable()
      }
      try Task.checkCancellation()
      return true
    }
  }

  private static func firstToFinish(
    _ first: @escaping @Sendable () async -> Void,
    _ second: @escaping @Sendable () async -> Void
  ) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask(operation: first)
      group.addTask(operation: second)
      await group.next()
      group.cancelAll()
    }
  }
}

/// The app's one retry loop. Every request goes through it exactly once; a caller that owns its own
/// retries passes `RetryPolicy.once` so retries never nest.
public enum NetworkRetry {
  public static func run<T: Sendable>(
    policy: RetryPolicy,
    idempotency: RequestIdempotency,
    clock: ClockClient,
    environment: RetryEnvironment = .live,
    reachable: (@Sendable () async -> Void)? = nil,
    operation: @Sendable (_ attempt: Int) async throws -> T
  ) async throws -> T {
    var schedule = RetrySchedule(policy: policy, clock: clock, environment: environment)
    var attempt = 0
    var mayHaveArrived = false

    while true {
      try Task.checkCancellation()
      attempt += 1
      do {
        return try await operation(attempt)
      } catch is CancellationError {
        throw CancellationError()
      } catch var error as OpenCodeClientError {
        error.attempts = attempt
        error.earlierAttemptMayHaveArrived = mayHaveArrived
        mayHaveArrived = error.mayHaveReachedServer
        let verdict = error.retryVerdict(idempotency: idempotency)
        guard let pause = schedule.next(verdict) else { throw error }
        _ = try await pause.run(reachable: reachable)
      }
    }
  }
}
