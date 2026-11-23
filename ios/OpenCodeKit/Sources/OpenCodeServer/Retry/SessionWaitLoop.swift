import Foundation
import OpenCodeCore

/// The audited experimental wait loop (`POST /api/experimental/session/{id}/wait`).
///
/// Each long poll and each active probe is sent once; this loop is their only retry layer. A poll
/// that runs out on a live run re-arms at once. A fast failure checks whether the run is still
/// active, then waits the shared session-wait backoff, for at most 12 fast failures. A caller that
/// owns retries gets its fast failure back after that one check.
public enum SessionWaitLoop {
  public static let maximumFastFailures = 12
  public static let fastFailureThreshold: Duration = .seconds(20)

  public static func run(
    clock: ClockClient,
    wait: @Sendable () async throws -> Void,
    isActive: @Sendable () async throws -> Bool,
    callerOwnsRetries: Bool = false,
    unit: @Sendable () -> Double = { Double.random(in: 0..<1) }
  ) async throws {
    var fastFailures = 0
    while true {
      try Task.checkCancellation()
      let started = clock.now()
      do {
        try await wait()
        return
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as OpenCodeClientError {
        let fast = clock.now() - started < fastFailureThreshold
        if fast { fastFailures += 1 }
        guard fastFailures < maximumFastFailures,
          error.retryVerdict(idempotency: .idempotent) != .permanent
        else { throw error }
        try Task.checkCancellation()
        let active: Bool
        do {
          active = try await isActive()
        } catch {
          throw error
        }
        try Task.checkCancellation()
        if !active { return }
        if !fast { continue }
        if callerOwnsRetries { throw error }
        let pause = RetryPolicy.sessionWait.delay(fastFailures, unit: unit())
        do { try await clock.sleep(pause) } catch { throw CancellationError() }
      }
    }
  }
}
