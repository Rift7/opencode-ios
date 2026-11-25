import ComposableArchitecture
import Foundation
import OpenCodeApp
import OpenCodeComposer
import OpenCodeCore
import OpenCodeDrawer
import OpenCodeServer
import OpenCodeSession
import OpenCodeSettings
import OpenCodeTestSupport
import Synchronization
import Testing

@MainActor
@Suite("Server edit integration", .serialized)
struct ServerEditIntegrationTests {
  private final class ScriptedStorage: KeyValueStorage, Sendable {
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

  private let draft = "Unsaved composer content"
  private let failedID = "failed-message"

  private func session(_ server: OpenCodeServer, draft: String) -> SessionFeature.State {
    let root = OpenCodeSession(
      id: "root",
      serverTitle: "Root",
      projectID: "p1",
      directory: "/work/opencode",
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    var state = SessionFeature.State(
      id: 1,
      server: server,
      selection: SessionSelection(serverID: server.persistenceID, sessionID: "root", intent: .browse),
      session: root
    )
    state.composer.draft = draft
    state.composer.revision = 1
    state.composer.contentRevision = 1
    state.composer.failedSends = [
      FailedComposerSend(
        messageID: failedID,
        text: "unresolved",
        quotes: [],
        delivery: .steer,
        target: .session(id: "root"),
        reason: .couldNotSend,
        failure: .definite
      )
    ]
    return state
  }

  private func state(
    server: OpenCodeServer = TestServer.server,
    savedServer: OpenCodeServer? = nil,
    savedServers: [OpenCodeServer]? = nil,
    session: SessionFeature.State? = nil,
    connectionServer: OpenCodeServer? = nil
  ) -> AppFeature.State {
    let selected = savedServer ?? server
    let servers = savedServers ?? [selected]
    return AppFeature.State(
      restore: .ready,
      connection: ConnectionFeature.State(
        id: 1,
        server: connectionServer ?? selected,
        phase: .connected,
        projects: TestServer.projects,
        isPinned: true
      ),
      home: HomeFeature.State(server: selected, hasLoaded: true, isPinned: true),
      session: session,
      sessionDestination: session?.selection,
      savedServer: selected,
      savedServers: servers,
      settings: SettingsFeature.State(isPresented: true, server: selected),
      isPinnedForUITest: true,
      savedData: .read
    )
  }

  private func makeStore(
    _ state: AppFeature.State,
    keychain: ScriptedStorage = ScriptedStorage(),
    drafts: ComposerDraftClient = ComposerDraftClient(save: { _, _ in .failure(.unavailable) })
  ) -> (TestStoreOf<AppFeature>, SharedStore, ScriptedStorage) {
    let store = SharedStore(defaults: OpenCodeCore.InMemoryStorage(), keychain: keychain)
    let test = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = store
      $0.networkPath = NetworkPathClient(
        current: { .online },
        updates: { AsyncStream { $0.finish() } },
        waitUntilAvailable: {}
      )
      $0.composerDrafts = drafts
      $0.clock = .testValue
      $0.dateClient = DateClient { Date(timeIntervalSince1970: 1_700_000_000) }
      $0.uuidClient = .incrementing()
    }
    test.exhaustivity = .off
    return (test, store, keychain)
  }

  private func seed(_ store: SharedStore, server: OpenCodeServer, servers: [OpenCodeServer]) {
    #expect(store.write(server, for: ServerSharedKeys.savedServer) == .success)
    #expect(store.write(servers, for: ServerSharedKeys.savedServers) == .success)
  }

  private func settle(_ store: TestStoreOf<AppFeature>) async {
    for _ in 0..<20 {
      await store.finish()
      await store.skipReceivedActions(strict: false)
    }
  }

  @Test("a second-write failure leaves no split and a restart restores the previous server")
  func secondWriteFailureAndRestart() async {
    let previous = TestServer.server
    let updated = OpenCodeServer(url: "http://127.0.0.1:4112", password: "test-token")
    let (store, shared, keychain) = makeStore(state())
    seed(shared, server: previous, servers: [previous])
    keychain.setFailAt(4)

    await store.send(
      .settings(
        .delegate(
          .saveServer(operationID: UUID(), previous: previous, updated: updated)
        )
      )
    )
    await settle(store)
    #expect(shared.result(ServerSharedKeys.savedServer) == .success(previous))
    #expect(shared.result(ServerSharedKeys.savedServers) == .success([previous]))
    #expect(store.state.savedServer == previous)
    #expect(store.state.serverWrite == nil)
    let restored = AppRestoreResult.read(shared)
    #expect(restored == .restored(server: previous, servers: [previous], cache: nil, notice: nil))
  }

  @Test("an active address or credential change reconnects by the previous identity and keeps the draft")
  func activeAddressChangeReconnectsAndTransfersDraft() async {
    let previous = TestServer.server
    let updated = OpenCodeServer(
      url: "http://127.0.0.1:4112",
      username: "new-user",
      password: "new-token"
    )
    var initial = state(session: session(previous, draft: draft))
    initial.sessionDestination = initial.session?.selection
    let (store, shared, _) = makeStore(initial)
    seed(shared, server: previous, servers: [previous])

    await store.send(
      .settings(
        .delegate(
          .saveServer(operationID: UUID(), previous: previous, updated: updated)
        )
      )
    )
    await settle(store)

    #expect(store.state.savedServer == updated)
    #expect(store.state.savedServers == [updated])
    #expect(store.state.connection?.server == updated)
    #expect(store.state.session == nil)
    #expect(shared.result(ServerSharedKeys.savedServer) == .success(updated))
    #expect(shared.result(ServerSharedKeys.savedServers) == .success([updated]))
    let key = ComposerDraftKey(serverID: previous.persistenceID, scope: .session("root"))
    let retained = store.state.retainedDraftTransfers[key]?.draft
    #expect(retained?.text == draft)
    #expect(retained?.failedSends.map(\.messageID) == [failedID])
  }

  @Test("removing the active server transfers the draft before disconnecting")
  func activeRemovalKeepsDraft() async {
    let previous = TestServer.server
    var initial = state(session: session(previous, draft: draft))
    initial.sessionDestination = initial.session?.selection
    let (store, shared, _) = makeStore(initial)
    seed(shared, server: previous, servers: [previous])

    await store.send(.settings(.delegate(.forgetServer(previous))))
    await settle(store)
    #expect(store.state.connection == nil)
    #expect(store.state.home == nil)
    #expect(store.state.session == nil)
    #expect(shared.result(ServerSharedKeys.savedServer) == .success(nil))
    #expect(shared.result(ServerSharedKeys.savedServers) == .success([]))
    let key = ComposerDraftKey(serverID: previous.persistenceID, scope: .session("root"))
    #expect(store.state.retainedDraftTransfers[key]?.draft.text == draft)
  }

  @Test("editing a non-active server updates the list without changing the connection")
  func nonActiveEditDoesNotReconnect() async {
    let active = TestServer.other
    let previous = TestServer.server
    let updated = OpenCodeServer(url: "http://127.0.0.1:4112", password: "test-token")
    let initial = state(
      server: active,
      savedServer: active,
      savedServers: [active, previous],
      connectionServer: active
    )
    let (store, shared, _) = makeStore(initial)
    seed(shared, server: active, servers: [active, previous])

    await store.send(
      .settings(
        .delegate(
          .saveServer(operationID: UUID(), previous: previous, updated: updated)
        )
      )
    )
    await settle(store)
    #expect(store.state.savedServer == active)
    #expect(store.state.connection?.server == active)
    #expect(store.state.savedServers == [updated, active])
    #expect(shared.result(ServerSharedKeys.savedServer) == .success(active))
    #expect(shared.result(ServerSharedKeys.savedServers) == .success([updated, active]))
  }

  @Test("a late completion after switching servers cannot reconnect the old server")
  func lateCompletionAfterSwitchIsFenced() async {
    let previous = TestServer.server
    let active = TestServer.other
    let updated = OpenCodeServer(url: "http://127.0.0.1:4112", password: "test-token")
    var initial = state(
      server: active,
      savedServer: active,
      savedServers: [active, previous],
      connectionServer: active
    )
    let operationID = UUID()
    initial.serverWrite = ServerWriteOperation(
      id: operationID,
      kind: .save(updated: updated),
      previous: previous
    )
    let (store, _, _) = makeStore(initial)
    await store.send(
      .serverWriteFinished(
        id: operationID,
        result: .success(.init(server: updated, servers: [updated, active]))
      )
    )
    #expect(store.state.savedServer == active)
    #expect(store.state.connection?.server == active)
    #expect(store.state.savedServers == [updated, active])
    #expect(store.state.serverWrite == nil)
  }

  @Test("a duplicate submission while a write is in flight is ignored")
  func duplicateSubmissionIsFenced() async {
    let previous = TestServer.server
    let first = OpenCodeServer(url: "http://127.0.0.1:4112", password: "test-token")
    let second = OpenCodeServer(url: "http://127.0.0.1:4113", password: "test-token")
    var initial = state()
    initial.serverWrite = ServerWriteOperation(
      id: UUID(),
      kind: .save(updated: first),
      previous: previous
    )
    let (store, _, _) = makeStore(initial)
    await store.send(
      .settings(
        .delegate(
          .saveServer(operationID: UUID(), previous: previous, updated: second)
        )
      )
    )
    if case .save(let updated) = store.state.serverWrite?.kind {
      #expect(updated == first)
    } else {
      Issue.record("the first operation was replaced")
    }
  }
}
