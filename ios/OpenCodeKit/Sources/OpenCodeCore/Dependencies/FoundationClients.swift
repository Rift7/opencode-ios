import ComposableArchitecture
import Foundation
import Synchronization

/// Why a connection probe could not reach a server. The app owns the user-facing copy so this
/// layer stays free of localized strings.
public enum ProbeFailure: Error, Equatable, Sendable {
  case notConfigured
  case unreachable
  case rejected
}

/// The connection probe. The live value is inert until the networking phase: it reports
/// `notConfigured` and never touches the network.
public struct ConnectionProbe: Sendable {
  public var check: @Sendable () async -> Result<Void, ProbeFailure>

  public init(check: @escaping @Sendable () async -> Result<Void, ProbeFailure>) {
    self.check = check
  }
}

extension ConnectionProbe: DependencyKey {
  public static let liveValue = ConnectionProbe { .failure(.notConfigured) }
  public static let testValue = ConnectionProbe { .failure(.notConfigured) }
}

extension DependencyValues {
  public var connectionProbe: ConnectionProbe {
    get { self[ConnectionProbe.self] }
    set { self[ConnectionProbe.self] = newValue }
  }
}

/// Wall-clock access. Reducers never call `Date()` directly so tests can pin time.
public struct DateClient: Sendable {
  public var now: @Sendable () -> Date

  public init(now: @escaping @Sendable () -> Date) {
    self.now = now
  }
}

extension DateClient: DependencyKey {
  public static let liveValue = DateClient { Date() }
  public static let testValue = DateClient { Date(timeIntervalSince1970: 0) }
}

extension DependencyValues {
  public var date: DateClient {
    get { self[DateClient.self] }
    set { self[DateClient.self] = newValue }
  }
}

/// Identifier generation. Tests get a deterministic, incrementing sequence.
public struct UuidClient: Sendable {
  public var uuid: @Sendable () -> UUID

  public init(uuid: @escaping @Sendable () -> UUID) {
    self.uuid = uuid
  }
}

extension UuidClient: DependencyKey {
  public static let liveValue = UuidClient { UUID() }

  public static let testValue: UuidClient = {
    let counter = Counter()
    return UuidClient {
      let next = counter.next()
      return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", next))!
    }
  }()

  /// A fresh deterministic generator, for a test that needs its own sequence.
  public static func incrementing(startingAt start: Int = 0) -> UuidClient {
    let counter = Counter(start: start)
    return UuidClient {
      let next = counter.next()
      return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", next))!
    }
  }
}

extension DependencyValues {
  public var uuid: UuidClient {
    get { self[UuidClient.self] }
    set { self[UuidClient.self] = newValue }
  }
}

private final class Counter: Sendable {
  private let value: Mutex<Int>

  init(start: Int = 0) {
    value = Mutex(start)
  }

  func next() -> Int {
    value.withLock { current in
      current += 1
      return current
    }
  }
}
