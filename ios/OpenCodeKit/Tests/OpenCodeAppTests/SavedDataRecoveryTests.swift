import ComposableArchitecture
import Foundation
import OpenCodeApp
import OpenCodeCore
import OpenCodeDrawer
import OpenCodeServer
import OpenCodeSession
import OpenCodeSettings
import OpenCodeTestSupport
import Synchronization
import Testing

@MainActor
@Suite("Saved-data recovery", .serialized)
struct SavedDataRecoveryTests {
  private final class FailOnceStorage: KeyValueStorage, Sendable {
    private let inner = OpenCodeCore.InMemoryStorage()
    private let state = Mutex<(writes: Int, failAt: Int?)>((0, nil))

    func setFailAt(_ value: Int?) { state.withLock { $0.failAt = value } }
    func read(_ key: String) -> StorageRead { inner.read(key) }
    func write(_ data: Data, for key: String) -> StorageWrite {
      let fail = state.withLock { value -> Bool in
        value.writes += 1
        return value.failAt == value.writes
      }
      return fail ? .failure(.unavailable) : inner.write(data, for: key)
    }
    func delete(_ key: String) -> StorageWrite {
      let fail = state.withLock { value -> Bool in
        value.writes += 1
        return value.failAt == value.writes
      }
      return fail ? .failure(.unavailable) : inner.delete(key)
    }
  }

  private let server = OpenCodeServer(
    url: "http://127.0.0.1:4110",
    username: "opencode",
    password: "token"
  )
  private let replacement = OpenCodeServer(
    url: "http://127.0.0.1:4112",
    username: "opencode",
    password: "replacement"
  )
  private let corrupt = Data("not json".utf8)

  private func make(
    keychain: FailOnceStorage = FailOnceStorage()
  ) -> (SharedStore, FailOnceStorage) {
    (
      SharedStore(defaults: OpenCodeCore.InMemoryStorage(), keychain: keychain),
      keychain
    )
  }

  private func makeStore(
    _ state: AppFeature.State,
    store: SharedStore
  ) -> TestStoreOf<AppFeature> {
    let test = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = store
      $0.networkPath = NetworkPathClient(
        current: { .online },
        updates: { AsyncStream { $0.finish() } },
        waitUntilAvailable: {}
      )
      $0.composerDrafts = .testValue
      $0.clock = .testValue
      $0.dateClient = DateClient { Date(timeIntervalSince1970: 1_700_000_000) }
    }
    test.exhaustivity = .off
    return test
  }

  private func settle(_ store: TestStoreOf<AppFeature>) async {
    for _ in 0..<20 {
      await store.finish()
      await store.skipReceivedActions(strict: false)
    }
  }

  private func corruptState(server: OpenCodeServer? = nil, servers: [OpenCodeServer] = []) -> AppFeature.State {
    AppFeature.State(
      restore: .corruptSavedServers,
      savedServer: server,
      savedServers: servers,
      isPinnedForUITest: true,
      savedData: .unreadable(.corrupt)
    )
  }

  @Test("ordinary writes refuse a corrupt list and preserve its raw bytes")
  func ordinarySaveRefusesCorruption() {
    let (store, _) = make()
    #expect(store.write(server, for: ServerSharedKeys.savedServer) == .success)
    #expect(store.writeRaw(corrupt, name: ServerSharedKeys.savedServers.name, storage: .keychain) == .success)

    let result = ServerWriteTransaction.save(
      server: replacement,
      servers: [replacement],
      store: store
    )
    #expect(result == .failure(.corrupt))
    if case .value(let saved) = store.read(ServerSharedKeys.savedServer) {
      #expect(saved == server)
    } else {
      Issue.record("selected server changed")
    }
    if case .value(let raw) = store.readRaw(name: ServerSharedKeys.savedServers.name, storage: .keychain) {
      #expect(raw == corrupt)
    } else {
      Issue.record("corrupt list was changed")
    }
    #expect(store.result(ServerSharedKeys.writeIntent) == .success(nil))
  }

  @Test("confirmed replacement recovers a corrupt list with a readable selected server")
  func replaceCorruptList() async {
    let (store, keychain) = make()
    #expect(store.write(server, for: ServerSharedKeys.savedServer) == .success)
    #expect(store.writeRaw(corrupt, name: ServerSharedKeys.savedServers.name, storage: .keychain) == .success)
    let restored = AppRestoreResult.read(store)
    #expect(
      restored
        == .restored(server: server, servers: [server], cache: nil, notice: .couldNotReadSavedServers)
    )

    var state = corruptState(server: replacement, servers: [replacement])
    state.showsReplaceSavedDataConfirmation = true
    let test = makeStore(state, store: store)
    await test.send(.replaceSavedDataConfirmed) {
      $0.showsReplaceSavedDataConfirmation = false
    }
    await settle(test)
    #expect(store.result(ServerSharedKeys.savedServer) == .success(replacement))
    #expect(store.result(ServerSharedKeys.savedServers) == .success([replacement]))
    #expect(store.result(ServerSharedKeys.writeIntent) == .success(nil))
    #expect(AppRestoreResult.read(store) == .restored(server: replacement, servers: [replacement], cache: nil, notice: nil))
    #expect(test.state.savedData == .read)
    #expect(test.state.restore == .ready)
  }

  @Test("confirmed replacement recovers a corrupt selected record with a readable list")
  func replaceCorruptSelected() async {
    let (store, _) = make()
    #expect(store.writeRaw(corrupt, name: ServerSharedKeys.savedServer.name, storage: .keychain) == .success)
    #expect(store.write([server], for: ServerSharedKeys.savedServers) == .success)
    #expect(
      AppRestoreResult.read(store)
        == .restored(server: server, servers: [server], cache: nil, notice: .couldNotReadSavedServers)
    )

    var state = corruptState(server: replacement, servers: [replacement])
    state.showsReplaceSavedDataConfirmation = true
    let test = makeStore(state, store: store)
    await test.send(.replaceSavedDataConfirmed) {
      $0.showsReplaceSavedDataConfirmation = false
    }
    await settle(test)

    #expect(store.result(ServerSharedKeys.savedServer) == .success(replacement))
    #expect(store.result(ServerSharedKeys.savedServers) == .success([replacement]))
    #expect(AppRestoreResult.read(store) == .restored(server: replacement, servers: [replacement], cache: nil, notice: nil))
  }

  @Test("Forget All recovers both corrupt records")
  func forgetAllBothCorrupt() async {
    let (store, _) = make()
    #expect(store.writeRaw(corrupt, name: ServerSharedKeys.savedServer.name, storage: .keychain) == .success)
    #expect(store.writeRaw(corrupt, name: ServerSharedKeys.savedServers.name, storage: .keychain) == .success)
    #expect(AppRestoreResult.read(store) == .corrupt)

    let test = makeStore(corruptState(), store: store)
    await test.send(.forgetSavedServersTapped)
    await settle(test)
    if case .missing = store.read(ServerSharedKeys.savedServer) {} else {
      Issue.record("selected server was not removed")
    }
    if case .missing = store.read(ServerSharedKeys.savedServers) {} else {
      Issue.record("saved list was not removed")
    }
    #expect(store.result(ServerSharedKeys.writeIntent) == .success(nil))
    #expect(AppRestoreResult.read(store) == .missing)
    #expect(test.state.savedData == .read)
    #expect(test.state.restore == .ready)
  }

  @Test("a manual connection followed by confirmed replacement recovers both corrupt records")
  func manualConnectionThenReplace() async {
    let (store, _) = make()
    #expect(store.writeRaw(corrupt, name: ServerSharedKeys.savedServer.name, storage: .keychain) == .success)
    #expect(store.writeRaw(corrupt, name: ServerSharedKeys.savedServers.name, storage: .keychain) == .success)

    var state = corruptState()
    state.showsReplaceSavedDataConfirmation = true
    state.connection = ConnectionFeature.State(
      id: 1,
      server: replacement,
      phase: .connected,
      isPinned: true
    )
    let test = makeStore(state, store: store)
    await test.send(.connection(.delegate(.verified(replacement, ServerInfo(version: "fixture", pid: 1)))))
    #expect(test.state.savedServer == replacement)
    await test.send(.replaceSavedDataConfirmed)
    await settle(test)

    #expect(store.result(ServerSharedKeys.savedServer) == .success(replacement))
    #expect(store.result(ServerSharedKeys.savedServers) == .success([replacement]))
    #expect(AppRestoreResult.read(store) == .restored(server: replacement, servers: [replacement], cache: nil, notice: nil))
    #expect(test.state.savedData == .read)
    #expect(test.state.restore == .ready)
  }

  @Test("a failed replacement preserves corrupt raw records and retries cleanly")
  func failedReplacementRetries() async {
    let (store, keychain) = make()
    #expect(store.write(server, for: ServerSharedKeys.savedServer) == .success)
    #expect(store.writeRaw(corrupt, name: ServerSharedKeys.savedServers.name, storage: .keychain) == .success)
    let writesBefore = 2
    keychain.setFailAt(writesBefore + 3)

    var state = corruptState(server: replacement, servers: [replacement])
    state.showsReplaceSavedDataConfirmation = true
    let test = makeStore(state, store: store)
    await test.send(.replaceSavedDataConfirmed)
    await settle(test)

    #expect(test.state.notice == .couldNotReplaceSavedData(.unavailable))
    #expect(test.state.savedData == .unreadable(.corrupt))
    #expect(
      AppRestoreResult.read(store)
        == .restored(server: server, servers: [server], cache: nil, notice: .couldNotReadSavedServers)
    )
    if case .value(let raw) = store.readRaw(name: ServerSharedKeys.savedServers.name, storage: .keychain) {
      #expect(raw == corrupt)
    } else {
      Issue.record("corrupt list was lost after a failed replacement")
    }

    keychain.setFailAt(nil)
    await test.send(.replaceSavedDataTapped)
    await test.send(.replaceSavedDataConfirmed)
    await settle(test)
    #expect(store.result(ServerSharedKeys.savedServer) == .success(replacement))
    #expect(store.result(ServerSharedKeys.savedServers) == .success([replacement]))
  }

  @Test("a failed Forget All preserves the recovery screen and retries")
  func failedForgetRetries() async {
    let (store, keychain) = make()
    #expect(store.writeRaw(corrupt, name: ServerSharedKeys.savedServer.name, storage: .keychain) == .success)
    #expect(store.writeRaw(corrupt, name: ServerSharedKeys.savedServers.name, storage: .keychain) == .success)
    let test = makeStore(corruptState(), store: store)
    keychain.setFailAt(3)
    await test.send(.forgetSavedServersTapped)
    await settle(test)
    #expect(test.state.savedData == .unreadable(.storage(.unavailable)))
    #expect(AppRestoreResult.read(store) == .corrupt)
    if case .value(let raw) = store.readRaw(name: ServerSharedKeys.savedServer.name, storage: .keychain) {
      #expect(raw == corrupt)
    } else {
      Issue.record("corrupt selected record was lost after a failed Forget All")
    }

    keychain.setFailAt(nil)
    await test.send(.forgetSavedServersTapped)
    await settle(test)
    if case .missing = store.read(ServerSharedKeys.savedServer) {} else {
      Issue.record("selected server was not removed")
    }
    if case .missing = store.read(ServerSharedKeys.savedServers) {} else {
      Issue.record("saved list was not removed")
    }
    #expect(test.state.savedData == .read)
  }
}
