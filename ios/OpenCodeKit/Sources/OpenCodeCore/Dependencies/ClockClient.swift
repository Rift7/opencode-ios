import ComposableArchitecture
import Foundation
import Synchronization

/// Monotonic time and waits. Retry schedules and stream watchdogs read this instead of calling
/// `Task.sleep` or `Date()` directly, so a test can run a backoff schedule in no time at all.
///
/// `now` is a monotonic duration since an unspecified origin; only differences are meaningful.
public struct ClockClient: Sendable {
  public var now: @Sendable () -> Duration
  public var sleep: @Sendable (Duration) async throws -> Void

  public init(
    now: @escaping @Sendable () -> Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) {
    self.now = now
    self.sleep = sleep
  }
}

extension ClockClient: DependencyKey {
  public static let liveValue: ClockClient = {
    let origin = DispatchTime.now().uptimeNanoseconds
    return ClockClient(
      now: {
        Duration.nanoseconds(Int64(clamping: DispatchTime.now().uptimeNanoseconds - origin))
      },
      sleep: { duration in
        guard duration > .zero else { return }
        try await Task.sleep(for: duration)
      }
    )
  }()

  /// Immediate: a wait returns at once and the clock does not move. Retry loops still count
  /// attempts and a caller can still cancel, so a test that forgets to inject a clock cannot
  /// hang on a backoff schedule.
  public static let testValue = ClockClient(now: { .zero }, sleep: { _ in })
}

extension DependencyValues {
  public var clock: ClockClient {
    get { self[ClockClient.self] }
    set { self[ClockClient.self] = newValue }
  }
}

extension ClockClient {
  /// A clock that advances only when something sleeps, and records every requested wait.
  public static func recording(startingAt start: Duration = .zero) -> RecordingClock {
    RecordingClock(startingAt: start)
  }

  /// A clock whose waits never finish until cancelled. A test that must keep a deadline from firing
  /// (a stream connect, say) uses it; the wait is cancelled when its scope ends.
  public static let suspended = ClockClient(
    now: { .zero },
    sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
  )

  /// A clock that holds each wait until the test releases it.
  public static func gate() -> GatedClock {
    GatedClock()
  }

  /// A clock the test moves by hand; its waits return at once without advancing time. Use it when a
  /// test must distinguish "a moment later" from "after a retry wait".
  public static func manual(startingAt start: Duration = .zero) -> ManualClock {
    ManualClock(startingAt: start)
  }
}

/// A clock the test advances explicitly; waits return at once.
public final class ManualClock: Sendable {
  private let state: Mutex<Duration>

  init(startingAt start: Duration) {
    state = Mutex(start)
  }

  public var elapsed: Duration {
    state.withLock { $0 }
  }

  public func advance(by duration: Duration) {
    state.withLock { $0 += duration }
  }

  public var client: ClockClient {
    ClockClient(
      now: { self.state.withLock { $0 } },
      sleep: { _ in try Task.checkCancellation() }
    )
  }
}

/// A scripted clock: waits return at once, advance the clock by their duration, and are recorded.
public final class RecordingClock: Sendable {
  private struct State {
    var elapsed: Duration
    var sleeps: [Duration] = []
  }

  private let state: Mutex<State>

  init(startingAt start: Duration) {
    state = Mutex(State(elapsed: start))
  }

  public var elapsed: Duration {
    state.withLock { $0.elapsed }
  }

  /// Every wait requested, in order.
  public var sleeps: [Duration] {
    state.withLock { $0.sleeps }
  }

  public var client: ClockClient {
    ClockClient(
      now: { self.state.withLock { $0.elapsed } },
      sleep: { duration in
        try Task.checkCancellation()
        self.state.withLock { state in
          state.sleeps.append(duration)
          state.elapsed += duration
        }
      }
    )
  }
}

/// A clock that holds each wait until the test releases it, so an effect's state is observable
/// between attempts.
public final class GatedClock: Sendable {
  private struct State {
    var waiters: [CheckedContinuation<Void, any Error>] = []
    var elapsed: Duration = .zero
    var requested: [Duration] = []
  }

  private let state = Mutex(State())

  public var elapsed: Duration {
    state.withLock { $0.elapsed }
  }

  public var requestedWaits: [Duration] {
    state.withLock { $0.requested }
  }

  public var pendingCount: Int {
    state.withLock { $0.waiters.count }
  }

  public var client: ClockClient {
    ClockClient(
      now: { self.state.withLock { $0.elapsed } },
      sleep: { duration in
        try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            self.state.withLock { state in
              state.requested.append(duration)
              state.waiters.append(continuation)
            }
          }
        } onCancel: {
          let cancelled = self.state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            let waiters = state.waiters
            state.waiters = []
            return waiters
          }
          for waiter in cancelled {
            waiter.resume(throwing: CancellationError())
          }
        }
        self.state.withLock { $0.elapsed += duration }
      }
    )
  }

  /// Lets the oldest waiting sleep finish.
  public func releaseNext() {
    let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
      guard !state.waiters.isEmpty else { return nil }
      return state.waiters.removeFirst()
    }
    waiter?.resume()
  }

  /// Lets every waiting sleep finish.
  public func releaseAll() {
    let waiters = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
      let waiters = state.waiters
      state.waiters = []
      return waiters
    }
    for waiter in waiters {
      waiter.resume()
    }
  }
}
