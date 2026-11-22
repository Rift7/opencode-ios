import ComposableArchitecture
import Foundation
import OpenCodeCore
import OpenCodeDrawer
import OpenCodeServer
import Testing

@MainActor
@Suite("Home feature")
struct HomeFeatureTests {
  private let server = OpenCodeServer(
    url: "http://127.0.0.1:4110",
    username: "opencode",
    password: "test-token"
  )

  private let otherServer = OpenCodeServer(
    url: "http://127.0.0.1:4111",
    username: "opencode",
    password: "other-token"
  )

  private func session(
    _ id: String,
    updated: TimeInterval = 1_700_000_000,
    idle: Int64? = 2_000,
    viewed: Int64? = 1_000,
    parent: String? = nil
  ) -> OpenCodeSession {
    OpenCodeSession(
      id: id,
      serverTitle: id,
      projectID: "p1",
      directory: "/work/opencode",
      updatedAt: Date(timeIntervalSince1970: updated),
      idleMilliseconds: idle,
      viewedMilliseconds: viewed,
      parentID: parent
    )
  }

  private func makeStore(
    _ state: HomeFeature.State,
    storage: SharedStore = SharedStore(defaults: InMemoryStorage(), keychain: InMemoryStorage()),
    client: OpenCodeClient = .testValue,
    snapshots: HomeSnapshotStore = .inMemory(),
    clock: ClockClient = .testValue
  ) -> TestStoreOf<HomeFeature> {
    let store = TestStore(initialState: state) {
      HomeFeature()
    } withDependencies: {
      $0.sharedStore = storage
      $0.openCodeClient = client
      $0.homeSnapshotStore = snapshots
      $0.clock = clock
      $0.dateClient = DateClient { Date(timeIntervalSince1970: 1_700_000_000) }
      $0.uuidClient = UuidClient.incrementing()
      $0.whatsNewCatalog = .migration
    }
    store.exhaustivity = .off
    return store
  }

  @Test("pinning and unpinning writes the server-scoped key")
  func pinAndUnpin() async {
    let storage = SharedStore(defaults: InMemoryStorage(), keychain: InMemoryStorage())
    let store = makeStore(
      HomeFeature.State(server: server, sessions: [session("a")], hasLoaded: true),
      storage: storage
    )

    await store.send(.pinToggled("a"))
    #expect(store.state.pinnedKeys == [store.state.key("a")])
    #expect(store.state.drawerSessions.pinned.map(\.id) == ["a"])
    if case .value(let pinned) = storage.read(HomeSharedKeys.pinnedSessions) {
      #expect(pinned == [store.state.key("a")])
    } else {
      Issue.record("pin was not persisted")
    }

    await store.send(.pinToggled("a"))
    #expect(store.state.pinnedKeys.isEmpty)
    #expect(store.state.drawerSessions.recents.map(\.id) == ["a"])
  }

  @Test("unread follows the idle watermark, then the local read date")
  func unreadState() async {
    let unread = session("unread", idle: 2_000, viewed: 1_000)
    let read = session("read", idle: 1_000, viewed: 1_000)
    let withoutIdle = session("no-idle", idle: nil, viewed: nil)
    let store = makeStore(
      HomeFeature.State(server: server, sessions: [unread, read, withoutIdle], hasLoaded: true),
      client: succeedingClient()
    )

    #expect(store.state.isUnread(unread))
    #expect(!store.state.isUnread(read))
    #expect(store.state.isUnread(withoutIdle))

    await store.send(.markReadTapped("unread"))
    #expect(!store.state.isUnread(store.state.session("unread")!))
    await store.finish()

    await store.send(.markUnreadTapped("read"))
    #expect(store.state.isUnread(read))
  }

  @Test("marking across servers cannot read the other server's records")
  func serverIsolation() async {
    let storage = SharedStore(defaults: InMemoryStorage(), keychain: InMemoryStorage())
    let first = makeStore(
      HomeFeature.State(server: server, sessions: [session("a")], hasLoaded: true),
      storage: storage
    )
    await first.send(.pinToggled("a"))
    await first.send(.markUnreadTapped("a"))

    let second = HomeFeature.State(
      server: otherServer,
      sessions: [session("a")],
      hasLoaded: true
    )
    let secondStore = makeStore(second, storage: storage)
    await secondStore.send(.localStateLoaded)

    #expect(!secondStore.state.isPinned("a"))
    #expect(!secondStore.state.manuallyUnreadKeys.contains(secondStore.state.key("a")))
    #expect(secondStore.state.manuallyUnreadKeys.contains(first.state.key("a")))
  }

  @Test("only roots that are not archived, hidden or deleted are visible")
  func visibleSessions() {
    let hidden = session("hidden")
    let archived = OpenCodeSession(
      id: "archived",
      serverTitle: "archived",
      projectID: "p1",
      directory: "/work/opencode",
      updatedAt: Date(),
      archivedAt: Date()
    )
    let child = session("child", parent: "root")
    let state = HomeFeature.State(
      server: server,
      sessions: [session("root"), hidden, archived, child],
      hiddenKeys: ["\(server.persistenceID)|hidden"],
      hasLoaded: true
    )

    #expect(state.visibleSessions.map(\.id) == ["root"])

    let searching = HomeFeature.State(
      server: server,
      sessions: [session("root"), hidden],
      hiddenKeys: ["\(server.persistenceID)|hidden"],
      searchText: "hidden",
      hasLoaded: true
    )
    #expect(searching.visibleSessions.map(\.id) == ["hidden"])
  }

  @Test("search filters locally and appends the server's matches")
  func search() async {
    let store = makeStore(
      HomeFeature.State(
        server: server,
        sessions: [session("alpha"), session("beta")],
        hasLoaded: true
      )
    )
    // No cursor means the local list is complete and no socket is opened.
    await store.send(.searchChanged("alp"))
    #expect(store.state.search == nil)
    #expect(store.state.visibleSessions.map(\.id) == ["alpha"])

    var paged = HomeFeature.State(server: server, sessions: [session("alpha")], hasLoaded: true)
    paged.page.next = "cursor-1"
    let storeWithServer = makeStore(paged, clock: .suspended)
    await storeWithServer.send(.searchChanged("gam"))
    #expect(storeWithServer.state.search?.isLoading == true)
    await storeWithServer.send(
      .searchLoaded(
        generation: storeWithServer.state.generation,
        query: "gam",
        token: storeWithServer.state.searchToken,
        appending: false,
        result: .success(SessionPage(sessions: [session("gamma")], next: nil))
      )
    )
    #expect(storeWithServer.state.visibleSessions.map(\.id) == ["gamma"])
  }

  @Test("a result for an older query is ignored")
  func staleSearch() async {
    var initial = HomeFeature.State(server: server, sessions: [session("alpha")], hasLoaded: true)
    initial.page.next = "cursor-1"
    let store = makeStore(initial, clock: .suspended)
    await store.send(.searchChanged("alpha"))
    let oldToken = store.state.searchToken
    await store.send(.searchChanged("beta"))
    await store.send(
      .searchLoaded(
        generation: store.state.generation,
        query: "alpha",
        token: oldToken,
        appending: false,
        result: .success(SessionPage(sessions: [session("wrong")], next: nil))
      )
    )
    #expect(store.state.search?.results.isEmpty == true)
  }

  @Test("an older page appends once and a stale cursor is ignored")
  func paging() async {
    var state = HomeFeature.State(server: server, sessions: [session("a")], hasLoaded: true)
    state.page.next = "cursor-1"
    let store = makeStore(state)

    await store.send(
      .olderLoaded(
        generation: store.state.generation,
        cursor: "cursor-1",
        result: .success(SessionPage(sessions: [session("b")], next: "cursor-2"))
      )
    )
    #expect(Set(store.state.sessions.map(\.id)) == ["a", "b"])
    #expect(store.state.page.next == "cursor-2")
    #expect(store.state.page.pagesLoaded == 1)

    await store.send(
      .olderLoaded(
        generation: store.state.generation,
        cursor: "cursor-1",
        result: .success(SessionPage(sessions: [session("c")], next: nil))
      )
    )
    #expect(Set(store.state.sessions.map(\.id)) == ["a", "b"])
  }

  @Test("a response from before a disconnect is ignored")
  func staleRefresh() async {
    let store = makeStore(
      HomeFeature.State(server: server, sessions: [session("a")], hasLoaded: true)
    )
    let oldGeneration = store.state.generation
    await store.send(.connectionChanged(isConnected: false))
    await store.send(
      .refreshed(
        generation: oldGeneration,
        request: 0,
        result: .success(HomeRefresh(sessions: [session("late")], next: nil, activeSessionIDs: []))
      )
    )
    #expect(store.state.sessions.map(\.id) == ["a"])
    #expect(!store.state.isLive)
  }

  @Test("a failed delete restores the row at its place and reports it")
  func deletionFailure() async {
    let failing = OpenCodeClient(
      health: { _ in throw OpenCodeClientError(.unsupported) },
      redeemPairing: { _ in throw OpenCodeClientError(.unsupported) },
      projects: { _ in throw OpenCodeClientError(.unsupported) },
      sessionPage: { _, _, _ in throw OpenCodeClientError(.unsupported) },
      getSession: { _, _ in throw OpenCodeClientError(.unsupported) },
      activeSessionIDs: { _ in throw OpenCodeClientError(.unsupported) },
      deleteSession: { _, _ in throw OpenCodeClientError(.status(500)) },
      events: { _, _ in
        AsyncThrowingStream { $0.finish(throwing: OpenCodeClientError(.unreachable)) }
      }
    )
    let store = makeStore(
      HomeFeature.State(
        server: server,
        sessions: [session("a"), session("b"), session("c")],
        hasLoaded: true
      ),
      client: failing
    )

    await store.send(.deleteTapped("b"))
    await store.send(.deleteConfirmed)
    #expect(store.state.sessions.map(\.id) == ["a", "c"])

    let backup = HomeFeature.State.DeletionBackup(
      session: session("b"),
      index: 1,
      wasActive: false,
      neededAttention: false
    )
    await store.receive(
      .deletionFinished(
        generation: store.state.generation,
        backup: backup,
        result: .failure(OpenCodeClientError(.status(500)))
      )
    )
    #expect(store.state.sessions.map(\.id) == ["a", "b", "c"])
    #expect(store.state.notice == .couldNotDelete(title: "b"))
    #expect(!store.state.recentDeletedIDs.contains("b"))
  }

  @Test("Catch Up puts waiting first, skips running and marks or keeps a card")
  func catchUp() async {
    let waiting = session("waiting", updated: 1_700_000_100)
    let running = session("running", updated: 1_700_000_300)
    let older = session("older", updated: 1_700_000_000)
    let state = HomeFeature.State(
      server: server,
      sessions: [older, running, waiting],
      activeSessionIDs: ["running"],
      attentionSessionIDs: ["waiting"],
      hasLoaded: true
    )
    let store = makeStore(state, client: succeedingClient())

    #expect(store.state.catchUpSessions.map(\.id) == ["waiting", "older"])

    await store.send(.catchUpTapped)
    #expect(store.state.catchUp?.queue == ["waiting", "older"])

    await store.send(.catchUpCardDismissed(sessionID: "waiting", disposition: .keepUnread))
    #expect(store.state.catchUp?.queue == ["older"])
    #expect(store.state.isUnread(waiting))

    await store.send(.catchUpUndoTapped)
    #expect(store.state.catchUp?.queue.first == "waiting")

    await store.send(.catchUpCardDismissed(sessionID: "waiting", disposition: .markRead))
    await store.finish()
    #expect(store.state.catchUp?.queue == ["older"])
    #expect(!store.state.isUnread(store.state.session("waiting")!))

    await store.send(.catchUpCardDismissed(sessionID: "older", disposition: .markRead))
    await store.finish()
    #expect(store.state.catchUp == nil)
    #expect(store.state.catchUpFinished)
    #expect(store.state.isDrawerOpen)
  }

  @Test("a new activity after a handled card brings it back")
  func catchUpSuperseded() async {
    let later = session("later", updated: 1_700_000_500)
    var state = HomeFeature.State(server: server, sessions: [session("a"), later], hasLoaded: true)
    state.catchUp = CatchUpState(
      queue: ["a"],
      handled: [
        CatchUpState.Handled(
          sessionID: "later",
          disposition: .markRead,
          idleMilliseconds: 2_000,
          updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
          neededAttention: false
        )
      ]
    )
    let store = makeStore(state, client: succeedingClient())

    #expect(store.state.catchUp?.queue == ["a"])

    // A newer idle watermark supersedes the handled record while the stack is open.
    let refreshed = [session("a"), session("later", updated: 1_700_000_600, idle: 5_000, viewed: 1_000)]
    await store.send(
      .refreshed(
        generation: store.state.generation,
        request: 0,
        result: .success(
          HomeRefresh(sessions: refreshed, next: nil, activeSessionIDs: [])
        )
      )
    )
    #expect(store.state.catchUp?.queue == ["a", "later"])
  }

  @Test("What's New marks its entries seen when it closes")
  func whatsNew() async {
    let storage = SharedStore(defaults: InMemoryStorage(), keychain: InMemoryStorage())
    let store = makeStore(
      HomeFeature.State(server: server, hasLoaded: true),
      storage: storage
    )
    #expect(store.state.showsWhatsNewRow)

    await store.send(.whatsNewTapped)
    #expect(store.state.whatsNew.isPresented)
    await store.send(.whatsNewDismissed)
    #expect(!store.state.showsWhatsNewRow)
    #expect(store.state.whatsNew.seenIDs == WhatsNewCatalog.migration.ids)
    if case .value(let seen) = storage.read(HomeSharedKeys.whatsNewSeen) {
      #expect(seen == WhatsNewCatalog.migration.ids)
    } else {
      Issue.record("seen state was not persisted")
    }
  }

  @Test("the Home snapshot is bounded and versioned")
  func snapshotBounds() async {
    let store = HomeSnapshotStore.inMemory()
    let sessions = (0..<60).map { session("session-\($0)") }
    let snapshot = HomeSnapshot(
      serverID: server.persistenceID,
      projects: [],
      sessions: sessions,
      activeSessionIDs: [],
      nextCursor: nil,
      capturedAt: Date()
    )
    #expect(snapshot.sessions.count == HomeSnapshot.maximumSessions)
    let written = await store.write(snapshot)
    #expect(written == .success(true))
    let read = await store.read(server.persistenceID)
    #expect(read == .success(snapshot))

    let stale = HomeSnapshot(
      version: 99,
      serverID: otherServer.persistenceID,
      projects: [],
      sessions: [],
      activeSessionIDs: [],
      nextCursor: nil,
      capturedAt: Date()
    )
    let rejected = await store.write(stale)
    #expect(rejected == .failure(.encoding))
  }

  @Test("a failed read receipt puts the previous read state back")
  func receiptFailure() async {
    let failing = OpenCodeClient(
      health: { _ in throw OpenCodeClientError(.unsupported) },
      redeemPairing: { _ in throw OpenCodeClientError(.unsupported) },
      projects: { _ in throw OpenCodeClientError(.unsupported) },
      sessionPage: { _, _, _ in throw OpenCodeClientError(.unsupported) },
      getSession: { _, _ in throw OpenCodeClientError(.unsupported) },
      activeSessionIDs: { _ in throw OpenCodeClientError(.unsupported) },
      viewSession: { _, _, _ in throw OpenCodeClientError(.status(500)) },
      events: { _, _ in
        AsyncThrowingStream { $0.finish(throwing: OpenCodeClientError(.unreachable)) }
      }
    )
    let store = makeStore(
      HomeFeature.State(server: server, sessions: [session("a")], hasLoaded: true),
      client: failing
    )
    await store.send(.markReadTapped("a"))
    let receiptID = store.state.receiptID(for: "a")!
    await store.receive(
      .readReceiptFinished(
        generation: store.state.generation,
        sessionID: "a",
        receiptID: receiptID,
        result: .failure(OpenCodeClientError(.status(500)))
      )
    )
    #expect(store.state.isUnread(store.state.session("a")!))
    #expect(store.state.notice == .couldNotMarkRead(title: "a"))
  }

  @Test("finishing the last card closes Catch Up onto the drawer")
  func catchUpFinish() async {
    var state = HomeFeature.State(server: server, sessions: [session("a")], hasLoaded: true)
    state.catchUp = CatchUpState(queue: ["a"])
    let store = makeStore(state, client: succeedingClient())
    await store.send(.catchUpCardDismissed(sessionID: "a", disposition: .keepUnread))
    #expect(store.state.catchUp == nil)
    #expect(store.state.catchUpFinished)
    #expect(store.state.isDrawerOpen)
  }


  @Test("snapshots stay per server and a successful write drops the legacy project cache")
  func snapshotMigration() async {
    let storage = SharedStore(defaults: InMemoryStorage(), keychain: InMemoryStorage())
    let legacy = [server.persistenceID: CachedServerSummary(projects: [], capturedAt: Date())]
    _ = storage.write(legacy, for: ServerSharedKeys.cachedSummaries)

    let snapshotStore = HomeSnapshotStore.inMemory()
    let first = HomeSnapshot(
      serverID: server.persistenceID,
      projects: [ServerProject(id: "p1", name: "One", directory: "/one")],
      sessions: [],
      activeSessionIDs: [],
      nextCursor: nil,
      capturedAt: Date(timeIntervalSince1970: 10)
    )
    let second = HomeSnapshot(
      serverID: otherServer.persistenceID,
      projects: [ServerProject(id: "p2", name: "Two", directory: "/two")],
      sessions: [],
      activeSessionIDs: [],
      nextCursor: nil,
      capturedAt: Date(timeIntervalSince1970: 20)
    )
    _ = await snapshotStore.write(first)
    _ = await snapshotStore.write(second)
    #expect(await snapshotStore.read(server.persistenceID) == .success(first))
    #expect(await snapshotStore.read(otherServer.persistenceID) == .success(second))

    let store = makeStore(
      HomeFeature.State(server: server, hasLoaded: true),
      storage: storage,
      snapshots: snapshotStore
    )
    await store.send(.snapshotWritten(generation: store.state.generation, result: .success(true)))
    #expect(storage.result(ServerSharedKeys.cachedSummaries) == .success([:]))
  }

  @Test("a failed Catch Up read receipt reports on the stack")
  func catchUpReceiptFailure() async {
    let failing = OpenCodeClient(
      health: { _ in throw OpenCodeClientError(.unsupported) },
      redeemPairing: { _ in throw OpenCodeClientError(.unsupported) },
      projects: { _ in throw OpenCodeClientError(.unsupported) },
      sessionPage: { _, _, _ in throw OpenCodeClientError(.unsupported) },
      getSession: { _, _ in throw OpenCodeClientError(.unsupported) },
      activeSessionIDs: { _ in throw OpenCodeClientError(.unsupported) },
      viewSession: { _, _, _ in throw OpenCodeClientError(.status(500)) },
      events: { _, _ in
        AsyncThrowingStream { $0.finish(throwing: OpenCodeClientError(.unreachable)) }
      }
    )
    var state = HomeFeature.State(
      server: server,
      sessions: [session("a"), session("b")],
      hasLoaded: true
    )
    state.catchUp = CatchUpState(queue: ["a", "b"])
    let store = makeStore(state, client: failing)
    await store.send(.catchUpCardDismissed(sessionID: "a", disposition: .markRead))
    let receiptID = store.state.receiptID(for: "a")!
    await store.receive(
      .readReceiptFinished(
        generation: store.state.generation,
        sessionID: "a",
        receiptID: receiptID,
        result: .failure(OpenCodeClientError(.status(500)))
      )
    )
    #expect(store.state.catchUp?.problem == "a")
    #expect(store.state.notice == nil)
  }

  private func waitFor(
    _ predicate: @MainActor () -> Bool,
    attempts: Int = 1_000
  ) async {
    for _ in 0..<attempts {
      if predicate() { return }
      try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("condition did not settle")
  }

  private func succeedingClient() -> OpenCodeClient {
    OpenCodeClient(
      health: { _ in throw OpenCodeClientError(.unsupported) },
      redeemPairing: { _ in throw OpenCodeClientError(.unsupported) },
      projects: { _ in throw OpenCodeClientError(.unsupported) },
      sessionPage: { _, _, _ in throw OpenCodeClientError(.unsupported) },
      getSession: { _, _ in throw OpenCodeClientError(.unsupported) },
      activeSessionIDs: { _ in throw OpenCodeClientError(.unsupported) },
      viewSession: { _, _, _ in },
      events: { _, _ in
        AsyncThrowingStream { $0.finish(throwing: OpenCodeClientError(.unreachable)) }
      }
    )
  }
}

