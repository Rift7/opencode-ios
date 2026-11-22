import ComposableArchitecture
import Foundation
import Network
import Synchronization

/// The phone's current network path, as a hint for when to retry. A satisfied path never means a
/// particular server is reachable, and an offline path never means the credentials are wrong.
public struct NetworkPath: Sendable, Equatable {
  public enum Status: String, Sendable, Equatable {
    case satisfied
    case requiresConnection
    case unsatisfied
  }

  public var status: Status
  /// Cellular or a personal hotspot.
  public var isExpensive: Bool
  /// Low Data Mode restricts this app.
  public var isConstrained: Bool

  public init(status: Status, isExpensive: Bool = false, isConstrained: Bool = false) {
    self.status = status
    self.isExpensive = isExpensive
    self.isConstrained = isConstrained
  }

  /// Only a path with nowhere to send is offline; `requiresConnection` is still tried.
  public var isOffline: Bool { status == .unsatisfied }

  public static let online = NetworkPath(status: .satisfied)
  public static let offline = NetworkPath(status: .unsatisfied)
}

/// Network-path observation. Tests inject a scripted path; the live value is one shared monitor.
public struct NetworkPathClient: Sendable {
  public var current: @Sendable () -> NetworkPath
  /// Every settled change from now on, starting with the current path when one is known.
  public var updates: @Sendable () -> AsyncStream<NetworkPath>
  /// Returns once sending could work, or at once when it already can.
  public var waitUntilAvailable: @Sendable () async -> Void

  public init(
    current: @escaping @Sendable () -> NetworkPath,
    updates: @escaping @Sendable () -> AsyncStream<NetworkPath>,
    waitUntilAvailable: @escaping @Sendable () async -> Void
  ) {
    self.current = current
    self.updates = updates
    self.waitUntilAvailable = waitUntilAvailable
  }
}

extension NetworkPathClient: DependencyKey {
  public static var liveValue: NetworkPathClient {
    let monitor = NetworkPathMonitor.shared
    return NetworkPathClient(
      current: { monitor.current },
      updates: { monitor.updates() },
      waitUntilAvailable: { await monitor.waitUntilAvailable() }
    )
  }

  /// Always online, never changes, never waits: a test that forgets an override cannot hang on a
  /// path notification.
  public static let testValue = NetworkPathClient(
    current: { .online },
    updates: { AsyncStream { $0.finish() } },
    waitUntilAvailable: {}
  )
}

extension DependencyValues {
  public var networkPath: NetworkPathClient {
    get { self[NetworkPathClient.self] }
    set { self[NetworkPathClient.self] = newValue }
  }
}

/// One process-wide `NWPathMonitor`. The monitor owns a serial queue; only the `Mutex` state and
/// continuations cross threads. `@unchecked Sendable` covers the monitor's own queue confinement.
private final class NetworkPathMonitor: @unchecked Sendable {
  static let shared = NetworkPathMonitor()

  private struct State {
    var path: NetworkPath?
    var continuations: [UUID: AsyncStream<NetworkPath>.Continuation] = [:]
  }

  private let state = Mutex(State())
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "ai.opencode.network-path")

  init() {
    monitor.pathUpdateHandler = { [weak self] path in
      self?.receive(path)
    }
    monitor.start(queue: queue)
  }

  var current: NetworkPath {
    state.withLock { $0.path } ?? .online
  }

  func updates() -> AsyncStream<NetworkPath> {
    AsyncStream { continuation in
      let id = UUID()
      let current = state.withLock { state -> NetworkPath? in
        state.continuations[id] = continuation
        return state.path
      }
      if let current {
        continuation.yield(current)
      }
      continuation.onTermination = { [weak self] _ in
        _ = self?.state.withLock { $0.continuations.removeValue(forKey: id) }
      }
    }
  }

  func waitUntilAvailable() async {
    if !current.isOffline { return }
    for await path in updates() where !path.isOffline {
      return
    }
  }

  private func receive(_ path: NWPath) {
    let snapshot = NetworkPath(
      status: {
        switch path.status {
        case .satisfied: .satisfied
        case .requiresConnection: .requiresConnection
        case .unsatisfied: .unsatisfied
        @unknown default: .unsatisfied
        }
      }(),
      isExpensive: path.isExpensive,
      isConstrained: path.isConstrained
    )
    let continuations = state.withLock { state -> [AsyncStream<NetworkPath>.Continuation] in
      if state.path == snapshot { return [] }
      state.path = snapshot
      return Array(state.continuations.values)
    }
    for continuation in continuations {
      continuation.yield(snapshot)
    }
  }
}
