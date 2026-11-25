import Foundation
import OpenCodeApp
import OpenCodeCore
import OpenCodeServer
import Synchronization
import Testing

@Suite("Server write transaction")
struct ServerWriteTransactionTests {
  private final class ScriptedStorage: KeyValueStorage, Sendable {
    private let inner: OpenCodeCore.InMemoryStorage
    private let state = Mutex<(writes: Int, failAt: Set<Int>)>((0, []))

    init(failAt: Int? = nil) {
      inner = OpenCodeCore.InMemoryStorage()
      if let failAt { state.withLock { $0.failAt = [failAt] } }
    }

    func read(_ key: String) -> StorageRead { inner.read(key) }

    func write(_ data: Data, for key: String) -> StorageWrite {
      let shouldFail = state.withLock { value -> Bool in
        value.writes += 1
        return value.failAt.contains(value.writes)
      }
      if shouldFail { return .failure(.unavailable) }
      return inner.write(data, for: key)
    }

    func delete(_ key: String) -> StorageWrite {
      let shouldFail = state.withLock { value -> Bool in
        value.writes += 1
        return value.failAt.contains(value.writes)
      }
      if shouldFail { return .failure(.unavailable) }
      return inner.delete(key)
    }

    func seed(_ data: Data, for key: String) { _ = inner.write(data, for: key) }

    func setFailAt(_ value: Int?) { state.withLock { $0.failAt = value.map { [$0] } ?? [] } }
    func setFailAt(_ values: Set<Int>) { state.withLock { $0.failAt = values } }

    func data(_ key: String) -> Data? {
      if case .value(let data) = inner.read(key) { return data }
      return nil
    }
  }

  private let before = OpenCodeServer(
    url: "http://10.0.0.2:4096",
    username: "opencode",
    password: "before"
  )
  private let after = OpenCodeServer(
    url: "http://10.0.0.3:4096",
    username: "opencode",
    password: "after"
  )

  private func store(_ keychain: any KeyValueStorage = ScriptedStorage()) -> SharedStore {
    SharedStore(defaults: OpenCodeCore.InMemoryStorage(), keychain: keychain)
  }

  private func seed(_ store: SharedStore) {
    #expect(store.write(before, for: ServerSharedKeys.savedServer) == .success)
    #expect(store.write([before], for: ServerSharedKeys.savedServers) == .success)
  }

  @Test("a failure at each write step leaves both records at their previous values")
  func failureAtEveryStepRollsBack() {
    for failAt in 1...4 {
      let keychain = ScriptedStorage()
      let store = store(keychain)
      seed(store)
      keychain.setFailAt(failAt + 2)
      let result = ServerWriteTransaction.save(
        server: after,
        servers: [after],
        store: store
      )
      if !result.isFailure { print("UNEXPECTED SUCCESS", failAt) }
      #expect(result.isFailure, "write \(failAt) unexpectedly committed")
      #expect(store.result(ServerSharedKeys.savedServer) == .success(before))
      #expect(store.result(ServerSharedKeys.savedServers) == .success([before]))
      #expect(store.result(ServerSharedKeys.writeIntent) == .success(nil))
    }
  }

  @Test("a successful write updates both records and clears the intent")
  func success() {
    let store = store()
    seed(store)
    let outcome = ServerWriteTransaction.save(server: after, servers: [after], store: store)
    #expect(outcome == .success(.init(server: after, servers: [after])))
    #expect(store.result(ServerSharedKeys.savedServer) == .success(after))
    #expect(store.result(ServerSharedKeys.savedServers) == .success([after]))
    #expect(store.result(ServerSharedKeys.writeIntent) == .success(nil))
  }

  @Test("removal uses the same transaction and rolls back a failed selected write")
  func removalRollsBack() {
    let keychain = ScriptedStorage()
    let store = store(keychain)
    seed(store)
    keychain.setFailAt(3)
    let result = ServerWriteTransaction.remove(server: nil, servers: [], store: store)
    #expect(result.isFailure)
    #expect(store.result(ServerSharedKeys.savedServer) == .success(before))
    #expect(store.result(ServerSharedKeys.savedServers) == .success([before]))
    #expect(store.result(ServerSharedKeys.writeIntent) == .success(nil))
  }

  @Test("a leftover intent from a crash is rolled back on the next read")
  func restartRecovery() {
    let keychain = ScriptedStorage()
    let store = store(keychain)
    seed(store)
    let intent = ServerWriteIntent(
      id: UUID(),
      beforeServer: before,
      beforeServers: [before],
      afterServer: after,
      afterServers: [after]
    )
    #expect(store.write(intent, for: ServerSharedKeys.writeIntent) == .success)
    #expect(store.write([after], for: ServerSharedKeys.savedServers) == .success)

    let restored = AppRestoreResult.read(store)
    #expect(restored == .restored(server: before, servers: [before], cache: nil, notice: nil))
    #expect(store.result(ServerSharedKeys.savedServer) == .success(before))
    #expect(store.result(ServerSharedKeys.savedServers) == .success([before]))
    #expect(store.result(ServerSharedKeys.writeIntent) == .success(nil))
  }

  @Test("rollback preserves a newer selected server and its list entry")
  func rollbackPreservesNewerSelection() {
    let newer = OpenCodeServer(url: "http://10.0.0.9:4096", password: "newer")
    let store = store()
    seed(store)
    let intent = ServerWriteIntent(
      id: UUID(),
      beforeServer: before,
      beforeServers: [before],
      afterServer: after,
      afterServers: [after]
    )
    #expect(store.write(intent, for: ServerSharedKeys.writeIntent) == .success)
    #expect(store.write([newer, before], for: ServerSharedKeys.savedServers) == .success)
    #expect(store.write(newer, for: ServerSharedKeys.savedServer) == .success)

    if case .success = ServerWriteTransaction.recover(store) {} else {
      Issue.record("recovery failed")
    }
    #expect(store.result(ServerSharedKeys.savedServer) == .success(newer))
    #expect(store.result(ServerSharedKeys.savedServers) == .success([newer, before]))
    #expect(store.result(ServerSharedKeys.writeIntent) == .success(nil))
  }

  @Test("a successful older edit returns the actual preserved newer selection")
  func successfulOlderReturnsActualSelection() {
    let newer = OpenCodeServer(url: "http://10.0.0.9:4096", password: "newer")
    let store = store()
    #expect(store.write(newer, for: ServerSharedKeys.savedServer) == .success)
    #expect(store.write([newer, before], for: ServerSharedKeys.savedServers) == .success)

    let result = ServerWriteTransaction.save(
      server: newer,
      servers: [newer, after, before],
      store: store
    )
    #expect(result == .success(.init(server: newer, servers: [newer, after, before])))
    #expect(store.result(ServerSharedKeys.savedServer) == .success(newer))
    #expect(store.result(ServerSharedKeys.savedServers) == .success([newer, after, before]))
    #expect(store.result(ServerSharedKeys.writeIntent) == .success(nil))
  }

  @Test("a corrupt intent blocks ordinary and confirmed writes without being overwritten")
  func corruptIntentIsNotOverwritten() {
    let store = store()
    seed(store)
    let corrupt = Data("not json".utf8)
    #expect(store.writeRaw(corrupt, name: ServerSharedKeys.writeIntent.name, storage: .keychain) == .success)

    #expect(
      ServerWriteTransaction.save(server: after, servers: [after], store: store)
        == .failure(.unfinishedIntent)
    )
    #expect(
      ServerWriteTransaction.replaceRecoveringCorrupt(server: after, servers: [after], store: store)
        == .failure(.unfinishedIntent)
    )
    if case .value(let raw) = store.readRaw(name: ServerSharedKeys.writeIntent.name, storage: .keychain) {
      #expect(raw == corrupt)
    } else {
      Issue.record("corrupt intent was overwritten")
    }
    #expect(store.result(ServerSharedKeys.savedServer) == .success(before))
    #expect(store.result(ServerSharedKeys.savedServers) == .success([before]))
    #expect(AppRestoreResult.read(store) == .corrupt)
  }

  @Test("a failed rollback keeps the intent until a later restart recovers it")
  func failedRollbackRemainsRecoverable() {
    let keychain = ScriptedStorage()
    let store = store(keychain)
    seed(store)
    // Intent and list writes succeed; the selected write and the rollback's list write fail.
    keychain.setFailAt([5, 6])
    let result = ServerWriteTransaction.save(server: after, servers: [after], store: store)
    #expect(result == .failure(.storage(.unavailable)))
    let originalIntent: ServerWriteIntent
    if case .value(.some(let intent)) = store.read(ServerSharedKeys.writeIntent) {
      originalIntent = intent
    } else {
      Issue.record("the unfinished intent was lost")
      return
    }

    // Another transaction cannot overwrite an unresolved intent.
    keychain.setFailAt([7])
    let blocked = ServerWriteTransaction.save(
      server: OpenCodeServer(url: "http://10.0.0.10:4096", password: "blocked"),
      servers: [],
      store: store
    )
    #expect(blocked == .failure(.storage(.unavailable)))
    #expect(store.result(ServerSharedKeys.writeIntent) == .success(originalIntent))

    if case .value(.some(let intent)) = store.read(ServerSharedKeys.writeIntent) {
      #expect(intent.beforeServer == before)
      #expect(intent.beforeServers == [before])
      #expect(intent.afterServer == after)
      #expect(intent.afterServers == [after])
    } else {
      Issue.record("the unfinished intent was lost")
    }

    keychain.setFailAt(Set<Int>())
    let restored = AppRestoreResult.read(store)
    #expect(restored == .restored(server: before, servers: [before], cache: nil, notice: nil))
    #expect(store.result(ServerSharedKeys.savedServer) == .success(before))
    #expect(store.result(ServerSharedKeys.savedServers) == .success([before]))
    #expect(store.result(ServerSharedKeys.writeIntent) == .success(nil))
  }
}

extension Result {
  fileprivate var isFailure: Bool {
    if case .failure = self { return true }
    return false
  }
}
