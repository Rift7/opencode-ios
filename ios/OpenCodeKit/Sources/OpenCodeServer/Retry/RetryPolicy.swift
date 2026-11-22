import Foundation

/// Whether a request can be sent twice without a second effect.
public enum RequestIdempotency: Sendable, Equatable {
  /// Reads, PUT, and POSTs the server dedupes by a client-made ID (a prompt's message ID, a
  /// session's ID).
  case idempotent
  /// A second copy could act twice (interrupt, fork, a permission reply). Retried only when the
  /// server provably did not act.
  case unsafe

  /// GET, HEAD, PUT and OPTIONS are idempotent by HTTP's definition. PATCH, POST and DELETE are not
  /// assumed to be; a call site opts in after checking the handler.
  public static func forMethod(_ method: String) -> RequestIdempotency {
    switch method.uppercased() {
    case "GET", "HEAD", "PUT", "OPTIONS": .idempotent
    default: .unsafe
    }
  }
}

/// Whether a failed attempt should be sent again, and how soon at the earliest.
public enum RetryVerdict: Sendable, Equatable {
  case transient(retryAfter: Duration?)
  case permanent
}

extension OpenCodeClientError {
  /// The one classification of failures for every retry loop.
  ///
  /// Retried: connection failures and timeouts, and 408, 429, 503, 502, 504 (and Cloudflare's
  /// 520–527/530). A request that isn't idempotent is retried only when the server provably did not
  /// act: no connection, or 408, 429, 503.
  public func retryVerdict(idempotency: RequestIdempotency) -> RetryVerdict {
    if isUnsupported { return .permanent }
    switch failure {
    case .streamEnded, .streamServerFailure, .streamOversizedFrame, .streamOverflow:
      // A new connection is the fix; the caller rehydrates from REST.
      return .transient(retryAfter: nil)
    default:
      break
    }
    if let transport {
      let mayRetry = transport == .notSent || idempotency == .idempotent
      return mayRetry ? .transient(retryAfter: retryAfter) : .permanent
    }
    guard let status = statusCode else { return .permanent }
    if status == 408 || status == 429 || status == 503 {
      return .transient(retryAfter: retryAfter)
    }
    if Self.isGatewayFailure(status) {
      return idempotency == .idempotent ? .transient(retryAfter: retryAfter) : .permanent
    }
    return .permanent
  }
}

/// Bounded exponential backoff with jitter, a retry window, and a wait for the network instead of
/// spending attempts while the phone is offline.
public struct RetryPolicy: Sendable, Equatable {
  /// Attempts in all, the first included; nil retries until cancelled.
  public var maxAttempts: Int?
  /// The ceiling before the first retry; it doubles for each one after.
  public var baseDelay: Duration
  /// No wait between attempts is longer than this.
  public var maxDelay: Duration
  /// How long to keep trying once the first attempt failed. Nil: bounded by `maxAttempts` alone.
  public var retryWindow: Duration?
  /// The longest a server's `Retry-After` is honoured.
  public var longestRetryAfter: Duration
  /// While the phone has no network path, wait for one (within the window).
  public var waitsForNetwork: Bool
  /// Keep retries responsive briefly, then resume exponential backoff.
  public var fastWindow: Duration?
  public var fastMaxDelay: Duration

  public init(
    maxAttempts: Int?,
    baseDelay: Duration,
    maxDelay: Duration,
    retryWindow: Duration?,
    longestRetryAfter: Duration = .seconds(30),
    waitsForNetwork: Bool = true,
    fastWindow: Duration? = nil,
    fastMaxDelay: Duration = .seconds(2)
  ) {
    self.maxAttempts = maxAttempts
    self.baseDelay = baseDelay
    self.maxDelay = maxDelay
    self.retryWindow = retryWindow
    self.longestRetryAfter = longestRetryAfter
    self.waitsForNetwork = waitsForNetwork
    self.fastWindow = fastWindow
    self.fastMaxDelay = fastMaxDelay
  }

  /// The longest wait before retry `n` (1 for the first retry).
  public func ceiling(_ n: Int) -> Duration {
    guard n > 0, baseDelay > .zero else { return .zero }
    let doublings = min(n - 1, 30)
    let uncapped = baseDelay * Double(1 << doublings)
    return min(maxDelay, uncapped)
  }

  public func delay(_ n: Int, unit: Double) -> Duration {
    Self.jitter(ceiling: ceiling(n), unit: unit)
  }

  /// "Equal jitter": uniformly between half the ceiling and the ceiling. Every wait is at least
  /// half its ceiling, so retries spread over a dropout instead of bunching at its start.
  public static func jitter(ceiling: Duration, unit: Double) -> Duration {
    let clamped = min(max(unit, 0), 1)
    return ceiling / 2 + (ceiling / 2) * clamped
  }

  /// Every request: five attempts over 7.5–15 s of waits, within 30 s of the first failure.
  public static let request = RetryPolicy(
    maxAttempts: 5,
    baseDelay: .seconds(1),
    maxDelay: .seconds(8),
    retryWindow: .seconds(30)
  )

  /// What the person sent: kept trying, at most 15 s apart, for five minutes of failures.
  public static let send = RetryPolicy(
    maxAttempts: nil,
    baseDelay: .seconds(1),
    maxDelay: .seconds(15),
    retryWindow: .seconds(300)
  )

  /// One attempt: the caller owns retrying, or a fast answer matters more.
  public static let once = RetryPolicy(
    maxAttempts: 1,
    baseDelay: .zero,
    maxDelay: .zero,
    retryWindow: nil,
    waitsForNetwork: false
  )

  /// The event stream doubles as the recovery probe: waits stay within 2 s for the first 15 s (a
  /// tunnel or Wi-Fi handoff), then double up to five minutes.
  public static let stream = RetryPolicy(
    maxAttempts: nil,
    baseDelay: .seconds(1),
    maxDelay: .seconds(300),
    retryWindow: nil,
    fastWindow: .seconds(15)
  )

  /// Local consumers falling behind need time, not another address.
  public static let streamOverflow = RetryPolicy(
    maxAttempts: nil,
    baseDelay: .seconds(1),
    maxDelay: .seconds(15),
    retryWindow: nil,
    waitsForNetwork: false
  )

  /// Waiting for a session's run to settle: about seven minutes.
  public static let sessionWait = RetryPolicy(
    maxAttempts: 30,
    baseDelay: .seconds(1),
    maxDelay: .seconds(16),
    retryWindow: nil
  )
}

/// The pure decision of one retry loop. Holds no clock and no randomness.
public struct RetryBackoff: Sendable {
  public enum Decision: Sendable, Equatable {
    case retry(after: Duration)
    /// Offline: wait at most this long for a network path, then retry at once.
    case waitForNetwork(upTo: Duration?)
    case giveUp
  }

  public let policy: RetryPolicy
  /// Failed attempts counted against `maxAttempts`. Failures while offline do not count.
  public private(set) var failures = 0
  private var slowFailures = 0

  public init(policy: RetryPolicy) {
    self.policy = policy
  }

  /// `elapsed` is time since the first failure; `unit` a random value in 0..<1.
  public mutating func decide(
    verdict: RetryVerdict,
    elapsed: Duration,
    offline: Bool,
    unit: Double
  ) -> Decision {
    guard case .transient(let retryAfter) = verdict else { return .giveUp }
    let remaining = policy.retryWindow.map { $0 - elapsed }
    if let remaining, remaining <= .zero { return .giveUp }
    if offline && policy.waitsForNetwork { return .waitForNetwork(upTo: remaining) }
    failures += 1
    if let maxAttempts = policy.maxAttempts, failures >= maxAttempts { return .giveUp }

    var delay: Duration
    if let window = policy.fastWindow {
      let ceiling: Duration
      if elapsed <= window {
        ceiling = min(policy.fastMaxDelay, policy.ceiling(failures))
      } else {
        slowFailures += 1
        ceiling = min(policy.maxDelay, policy.fastMaxDelay * Double(1 << min(slowFailures, 30)))
      }
      delay = RetryPolicy.jitter(ceiling: ceiling, unit: unit)
    } else {
      delay = policy.delay(failures, unit: unit)
    }

    if let retryAfter {
      if retryAfter > policy.longestRetryAfter { return .giveUp }
      delay = max(delay, retryAfter)
    }
    if let remaining, delay > remaining { return .giveUp }
    return .retry(after: delay)
  }

  /// Whether to try again with no wait at all: transient, within the window and attempts.
  public mutating func decideNow(verdict: RetryVerdict, elapsed: Duration) -> Bool {
    guard case .transient = verdict else { return false }
    if let window = policy.retryWindow, elapsed >= window { return false }
    failures += 1
    if let maxAttempts = policy.maxAttempts, failures >= maxAttempts { return false }
    return true
  }

  /// A healthy connection: the next failure starts over.
  public mutating func reset() {
    failures = 0
    slowFailures = 0
  }
}
