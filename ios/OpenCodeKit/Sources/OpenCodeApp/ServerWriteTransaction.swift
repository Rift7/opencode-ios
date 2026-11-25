import Foundation
import OpenCodeCore
import OpenCodeServer

/// The two-key server records (`savedServer` and `savedServers`) cannot be written atomically in the
/// Keychain. A Keychain intent records both sides; a crash or a failed second write is rolled back
/// on the next read, so the selected server and the list cannot silently disagree.
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

  /// Saves a selected server plus its list. The list is written first; if the selected record then
  /// fails, both records are rolled back. A concurrent newer selection is left in place.
  public static func save(
    server: OpenCodeServer?,
    servers: [OpenCodeServer],
    store: SharedStore
  ) -> Result<Outcome, Failure> {
    apply(server: server, servers: servers, store: store)
  }

  /// Forgets a server, keeping the list and selected record coherent.
  public static func remove(
    server: OpenCodeServer?,
    servers: [OpenCodeServer],
    store: SharedStore
  ) -> Result<Outcome, Failure> {
    apply(server: server, servers: servers, store: store)
  }

  /// Startup recovery: any unfinished intent is rolled back to the records it started from. A
  /// fully committed write clears its intent before the UI reports success, so a leftover intent
  /// always means the operation did not complete.
  public static func recover(_ store: SharedStore) -> Result<Void, Failure> {
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
      return rollback(intent, store: store)
    }
  }

  private static func apply(
    server: OpenCodeServer?,
    servers: [OpenCodeServer],
    store: SharedStore
  ) -> Result<Outcome, Failure> {
    let beforeServer: OpenCodeServer?
    switch readServer(store) {
    case .success(let value): beforeServer = value
    case .failure(let failure): return .failure(failure)
    }
    let beforeServers: [OpenCodeServer]
    switch readServers(store) {
    case .success(let value): beforeServers = value
    case .failure(let failure): return .failure(failure)
    }

    let intent = ServerWriteIntent(
      id: UUID(),
      beforeServer: beforeServer,
      beforeServers: beforeServers,
      afterServer: server,
      afterServers: servers
    )
    if case .failure(let failure) = store.write(intent, for: ServerSharedKeys.writeIntent) {
      return .failure(.storage(failure))
    }
    if case .failure(let failure) = store.write(servers, for: ServerSharedKeys.savedServers) {
      _ = rollback(intent, store: store)
      return .failure(.storage(failure))
    }

    // A newer selection written while this operation was in flight wins; never overwrite it with
    // the edited server's old selection.
    let current: OpenCodeServer?
    switch readServer(store) {
    case .success(let value): current = value
    case .failure(let failure):
      _ = rollback(intent, store: store)
      return .failure(failure)
    }
    if current == beforeServer || current == server {
      let write: StorageWrite
      if let server {
        write = store.write(server, for: ServerSharedKeys.savedServer)
      } else {
        write = store.delete(ServerSharedKeys.savedServer)
      }
      if case .failure(let failure) = write {
        _ = rollback(intent, store: store)
        return .failure(.storage(failure))
      }
    }

    if case .failure(let failure) = store.delete(ServerSharedKeys.writeIntent) {
      _ = rollback(intent, store: store)
      return .failure(.storage(failure))
    }
    return .success(Outcome(server: server, servers: servers))
  }

  private static func rollback(
    _ intent: ServerWriteIntent,
    store: SharedStore
  ) -> Result<Void, Failure> {
    if case .failure(let failure) = store.write(intent.beforeServers, for: ServerSharedKeys.savedServers) {
      return .failure(.storage(failure))
    }
    let current: OpenCodeServer?
    switch readServer(store) {
    case .success(let value): current = value
    case .failure(let failure): return .failure(failure)
    }
    if current != intent.beforeServer, current != intent.afterServer {
      // A newer selection exists; keep it rather than restoring this operation's old choice.
    } else {
      let write: StorageWrite
      if let before = intent.beforeServer {
        write = store.write(before, for: ServerSharedKeys.savedServer)
      } else {
        write = store.delete(ServerSharedKeys.savedServer)
      }
      if case .failure(let failure) = write { return .failure(.storage(failure)) }
    }
    if case .failure(let failure) = store.delete(ServerSharedKeys.writeIntent) {
      return .failure(.storage(failure))
    }
    return .success(())
  }

  private static func readServer(_ store: SharedStore) -> Result<OpenCodeServer?, Failure> {
    switch store.read(ServerSharedKeys.savedServer) {
    case .missing, .value(nil): return .success(nil)
    case .value(.some(let server)): return .success(server)
    case .undecodable: return .failure(.corrupt)
    case .failure(let failure): return .failure(.storage(failure))
    }
  }

  private static func readServers(_ store: SharedStore) -> Result<[OpenCodeServer], Failure> {
    switch store.read(ServerSharedKeys.savedServers) {
    case .missing: return .success([])
    case .value(let servers): return .success(servers)
    case .undecodable: return .failure(.corrupt)
    case .failure(let failure): return .failure(.storage(failure))
    }
  }
}
