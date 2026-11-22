import Foundation
import OpenCodeCore

extension NetworkPathClient {
  /// The retry loop's view of the world: a known-offline path waits for the monitor instead of
  /// spending attempts, and jitter stays live.
  public var retryEnvironment: RetryEnvironment {
    RetryEnvironment(
      random: { Double.random(in: 0..<1) },
      isOffline: { current().isOffline },
      networkAvailable: { await waitUntilAvailable() }
    )
  }
}
