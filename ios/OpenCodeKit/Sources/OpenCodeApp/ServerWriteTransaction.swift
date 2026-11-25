import Foundation
import OpenCodeCore
import OpenCodeServer
import Synchronization

/// The single ownership boundary for the two saved-server records and their transaction intent.
///
/// Every production writer (Settings edit/removal, pairing/connection persistence, forget-all and
/// saved-data replacement) enters here. One process-wide mutex serializes the whole transaction, so
/// an unfinished intent is never overwritten and a reader never observes a half-applied pair. A
/// Keychain intent holds both before and after states; a failed or interrupted write is rolled back
/// before another operation or a launch read may proceed.
public enum ServerWriteTransaction {
  public enum Failure: Error, Equatable, Sendable {
    case storage(StorageFailure)
    case corrupt
  }

  public struct Outcome: Equatable, Sendable {
    public var server: OpenCodeServer?
    public var servers: [OpenCodeServer]

    public init(server: OpenCodeServer?, servers: [OpenCodeServer]) {
      self.server = server
      self.servers = servers
    }
  }

  /// A launch read that preserves the difference between an unreadable selected record and an
  /// unreadable list, so the existing explicit-recovery UI remains available.
  public struct Records: Equatable, Sendable {
    public var server: OpenCodeServer?
    public var servers: [OpenCodeServer]
    public var serverUnreadable: Bool
    public var listUnreadable: Bool

    public init(
      server: OpenCodeServer?,
      servers: [OpenCodeServer],
      serverUnreadable: Bool,
      listUnreadable: Bool
    ) {
      self.server = server
      self.servers = servers
      self.serverUnreadable = serverUnreadable
      self.listUnreadable = listUnreadable
    }
  }

  private static let boundary = Mutex<()>(())

  /// The committed records, after recovering any unfinished intent. This is the only read path a
  /// launch or feature should use for the selected server and list.
  public static func snapshot(store: SharedStore) -> Result<Outcome, Failure> {
    boundary.withLock { _ in
      switch recoverLocked(store: store) {
      case .success: return readOutcomeLocked(store: store)
      case .failure(let failure): return .failure(failure)
      }
    }
  }

  /// Reads both records after recovery under the ownership boundary, keeping partial-corruption
  /// facts for launch.
  public static func read(store: SharedStore) -> Result<Records, Failure> {
    boundary.withLock { _ in
      switch recoverLocked(store: store) {
      case .failure(let failure): return .failure(failure)
      case .success:
        var server: OpenCodeServer?
        var serverUnreadable = false
        switch store.read(ServerSharedKeys.savedServer) {
        case .missing: break
        case .value(let value): server = value
        case .undecodable: serverUnreadable = true
        case .failure(let failure): return .failure(.storage(failure))
        }
        var servers: [OpenCodeServer] = []
        var listUnreadable = false
        switch store.read(ServerSharedKeys.savedServers) {
        case .missing: break
        case .value(let value): servers = value
        case .undecodable: listUnreadable = true
        case .failure(let failure): return .failure(.storage(failure))
        }
        if let server, !servers.contains(server) {
          servers.insert(server, at: 0)
        }
        return .success(
          Records(
            server: server ?? servers.first,
            servers: servers,
            serverUnreadable: serverUnreadable,
            listUnreadable: listUnreadable
          )
        )
      }
    }
  }

  public static func save(
    server: OpenCodeServer?,
    servers: [OpenCodeServer],
    store: SharedStore
  ) -> Result<Outcome, Failure> {
    apply(server: server, servers: servers, store: store)
  }

  public static func remove(
    server: OpenCodeServer?,
    servers: [OpenCodeServer],
    store: SharedStore
  ) -> Result<Outcome, Failure> {
    apply(server: server, servers: servers, store: store)
  }

  /// Startup/feature recovery. A leftover intent always means its operation did not finish; it is
  /// rolled back before anything trusts either record. Failure leaves the intent in place.
  public static func recover(_ store: SharedStore) -> Result<Void, Failure> {
    boundary.withLock { _ in recoverLocked(store: store) }
  }

  private static func apply(
    server: OpenCodeServer?,
    servers: [OpenCodeServer],
    store: SharedStore
  ) -> Result<Outcome, Failure> {
    boundary.withLock { _ in
      // An unfinished intent must be resolved before another transaction may write.
      if case .failure(let failure) = recoverLocked(store: store) {
        return .failure(failure)
      }

      let before: Outcome
      switch readOutcomeLocked(store: store) {
      case .success(let value): before = value
      case .failure(let failure): return .failure(failure)
      }

      let intent = ServerWriteIntent(
        id: UUID(),
        beforeServer: before.server,
        beforeServers: before.servers,
        afterServer: server,
        afterServers: servers
      )
      if case .failure(let failure) = store.write(intent, for: ServerSharedKeys.writeIntent) {
        return .failure(.storage(failure))
      }
      let listWrite: StorageWrite =
        servers.isEmpty
        ? store.delete(ServerSharedKeys.savedServers)
        : store.write(servers, for: ServerSharedKeys.savedServers)
      if case .failure(let failure) = listWrite {
        return rollbackFailure(intent, store: store, original: failure)
      }
      let current: OpenCodeServer?
      switch readServerLocked(store: store) {
      case .success(let value): current = value
      case .failure(let failure):
        return rollbackFailure(intent, store: store, original: storageFailure(failure))
      }
      if current == before.server || current == server || current == nil {
        let selectedWrite: StorageWrite
        if let server {
          selectedWrite = store.write(server, for: ServerSharedKeys.savedServer)
        } else {
          selectedWrite = store.delete(ServerSharedKeys.savedServer)
        }
        if case .failure(let failure) = selectedWrite {
          return rollbackFailure(intent, store: store, original: failure)
        }
      } else if let current, !servers.contains(current) {
        // An uncoordinated newer selection exists. Keep it and make the list contain it.
        let repaired = [current] + servers.filter { $0 != current }
        if case .failure(let failure) = store.write(repaired, for: ServerSharedKeys.savedServers) {
          return rollbackFailure(intent, store: store, original: failure)
        }
      }
      if case .failure(let failure) = store.delete(ServerSharedKeys.writeIntent) {
        return rollbackFailure(intent, store: store, original: failure)
      }
      return readOutcomeLocked(store: store)
    }
  }

  /// On an operation failure, attempt a complete rollback. If rollback also fails, the original
  /// intent remains and the failure is reported; a later recovery retries from the same before/after
  /// records.
  private static func rollbackFailure(
    _ intent: ServerWriteIntent,
    store: SharedStore,
    original: StorageFailure
  ) -> Result<Outcome, Failure> {
    switch rollbackLocked(intent, store: store) {
    case .success:
      return .failure(.storage(original))
    case .failure(let recovery):
      _ = recovery
      return .failure(.storage(original))
    }
  }

  private static func rollbackLocked(
    _ intent: ServerWriteIntent,
    store: SharedStore
  ) -> Result<Void, Failure> {
    let current: Outcome
    switch readOutcomeLocked(store: store) {
    case .success(let value): current = value
    case .failure(let failure): return .failure(failure)
    }

    // Preserve entries that were never part of this operation (for example a server paired by a
    // newer writer) and the newer selected server, while removing this operation's after-only
    // additions. The result is always a coherent pair: the selected server is in the list.
    var restoredServers = intent.beforeServers.filter { !intent.afterServers.contains($0) }
    for server in intent.beforeServers where !restoredServers.contains(server) {
      restoredServers.append(server)
    }
    for server in current.servers
    where !intent.afterServers.contains(server) && !restoredServers.contains(server) {
      restoredServers.append(server)
    }

    let newerSelection =
      current.server != intent.beforeServer && current.server != intent.afterServer
      ? current.server : nil
    let selected = newerSelection ?? intent.beforeServer
    if let selected, !restoredServers.contains(selected) {
      restoredServers.insert(selected, at: 0)
    }

    if case .failure(let failure) = store.write(restoredServers, for: ServerSharedKeys.savedServers) {
      return .failure(.storage(failure))
    }
    let selectedWrite: StorageWrite
    if let selected {
      selectedWrite = store.write(selected, for: ServerSharedKeys.savedServer)
    } else {
      selectedWrite = store.delete(ServerSharedKeys.savedServer)
    }
    if case .failure(let failure) = selectedWrite {
      return .failure(.storage(failure))
    }
    if case .failure(let failure) = store.delete(ServerSharedKeys.writeIntent) {
      return .failure(.storage(failure))
    }
    return .success(())
  }

  private static func readServerLocked(store: SharedStore) -> Result<OpenCodeServer?, Failure> {
    switch store.read(ServerSharedKeys.savedServer) {
    case .missing: return .success(nil)
    case .value(let value): return .success(value)
    case .undecodable: return .failure(.corrupt)
    case .failure(let failure): return .failure(.storage(failure))
    }
  }

  private static func storageFailure(_ failure: Failure) -> StorageFailure {
    switch failure {
    case .storage(let storage): storage
    case .corrupt: .encoding
    }
  }

  /// Reads the two records under the same boundary and reports the actual committed pair.
  private static func readOutcomeLocked(store: SharedStore) -> Result<Outcome, Failure> {
    let server: OpenCodeServer?
    switch store.read(ServerSharedKeys.savedServer) {
    case .missing: server = nil
    case .value(let value): server = value
    case .undecodable: return .failure(.corrupt)
    case .failure(let failure): return .failure(.storage(failure))
    }
    let servers: [OpenCodeServer]
    switch store.read(ServerSharedKeys.savedServers) {
    case .missing: servers = []
    case .value(let value): servers = value
    case .undecodable: return .failure(.corrupt)
    case .failure(let failure): return .failure(.storage(failure))
    }
    let coherent: [OpenCodeServer]
    if let server, !servers.contains(server) {
      coherent = [server] + servers
    } else {
      coherent = servers
    }
    return .success(Outcome(server: server ?? coherent.first, servers: coherent))
  }

  private static func recoverLocked(store: SharedStore) -> Result<Void, Failure> {
    switch store.read(ServerSharedKeys.writeIntent) {
    case .missing:
      return .success(())
    case .failure(let failure):
      return .failure(.storage(failure))
    case .undecodable:
      return .failure(.corrupt)
    case .value(.none):
      return .success(())
    case .value(.some(let intent)):
      return rollbackLocked(intent, store: store)
    }
  }
}
