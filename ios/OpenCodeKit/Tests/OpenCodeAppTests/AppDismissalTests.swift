import ComposableArchitecture
import Foundation
import OpenCodeApp
import OpenCodeComposer
import OpenCodeCore
import OpenCodeDrawer
import OpenCodeServer
import OpenCodeSession
import Synchronization
import Testing

@MainActor
@Suite("App composer persistence handoff", .serialized)
struct AppDismissalTests {
  private actor SaveGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
      if open { return }
      await withCheckedContinuation { waiters.append($0) }
    }

    func releaseAll() {
      open = true
      for waiter in waiters { waiter.resume() }
      waiters.removeAll()
    }
  }

  private actor SaveQueue {
    private var permits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var attempted = 0

    func wait() async {
      attempted += 1
      if permits > 0 {
        permits -= 1
        return
      }
      await withCheckedContinuation { waiters.append($0) }
    }

    func releaseNext() {
      if waiters.isEmpty {
        permits += 1
      } else {
        waiters.removeFirst().resume()
      }
    }

    func releaseAll() {
      permits += waiters.count
      for waiter in waiters { waiter.resume() }
      waiters.removeAll()
    }

    var attempts: Int { attempted }
  }

  private actor DraftBackend {
    var records: [String: ComposerDraft] = [:]
    var failSave = false
    var gate: SaveGate?
    var saveQueue: SaveQueue?
    var transferQueue: SaveQueue?

    func save(_ draft: ComposerDraft, key: ComposerDraftKey) async -> ComposerDraftSave {
      if let saveQueue { await saveQueue.wait() }
      if let gate { await gate.wait() }
      if failSave { return .failure(.unavailable) }
      records[key.storageKey] = draft
      return .saved
    }

    func saveIfNewer(_ draft: ComposerDraft, key: ComposerDraftKey) async -> ComposerDraftSave {
      if let current = records[key.storageKey], current.supersedes(draft) {
        return .saved
      }
      return await save(draft, key: key)
    }

    func removeIfNotNewer(_ draft: ComposerDraft, key: ComposerDraftKey) async -> ComposerDraftSave {
      if let current = records[key.storageKey], current.supersedes(draft) {
        return .saved
      }
      return await remove(key)
    }

    func saveDeparting(_ draft: ComposerDraft, key: ComposerDraftKey) async -> ComposerDraftSave {
      if let transferQueue { await transferQueue.wait() }
      if let current = records[key.storageKey], current.supersedes(draft) {
        return .saved
      }
      if failSave { return .failure(.unavailable) }
      records[key.storageKey] = draft
      return .saved
    }

    func removeDeparting(_ draft: ComposerDraft, key: ComposerDraftKey) async -> ComposerDraftSave {
      if let transferQueue { await transferQueue.wait() }
      if let current = records[key.storageKey], current.supersedes(draft) {
        return .saved
      }
      records[key.storageKey] = nil
      return .saved
    }

    func remove(_ key: ComposerDraftKey) -> ComposerDraftSave {
      records[key.storageKey] = nil
      return .saved
    }

    func load(_ key: ComposerDraftKey) -> ComposerDraftLoad {
      records[key.storageKey].map(ComposerDraftLoad.found) ?? .missing
    }

    func setGate(_ gate: SaveGate?) { self.gate = gate }
    func setSaveQueue(_ queue: SaveQueue?) { saveQueue = queue }
    func setTransferQueue(_ queue: SaveQueue?) { transferQueue = queue }
    func setFailure(_ value: Bool) { failSave = value }
    func stored(_ key: ComposerDraftKey) -> ComposerDraft? { records[key.storageKey] }
  }

  private func client(_ backend: DraftBackend) -> ComposerDraftClient {
    ComposerDraftClient(
      load: { await backend.load($0) },
      save: { await backend.save($0, key: $1) },
      remove: { await backend.remove($0) },
      saveIfNewer: { await backend.saveIfNewer($0, key: $1) },
      removeIfNotNewer: { await backend.removeIfNotNewer($0, key: $1) },
      saveDeparting: { await backend.saveDeparting($0, key: $1) },
      removeDeparting: { await backend.removeDeparting($0, key: $1) }
    )
  }

  private func server() -> OpenCodeServer {
    OpenCodeServer(
      url: "http://127.0.0.1:4110",
      username: "opencode",
      password: "test-token"
    )
  }

  private func root(_ id: String = "a", title: String? = nil) -> OpenCodeSession {
    OpenCodeSession(
      id: id,
      serverTitle: title ?? id,
      projectID: "p1",
      directory: "/work/opencode",
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  private func session(
    _ id: String = "a",
    draft: String = "Unsaved draft"
  ) -> SessionFeature.State {
    let server = server()
    var state = SessionFeature.State(
      id: 1,
      server: server,
      selection: SessionSelection(
        serverID: server.persistenceID,
        sessionID: id,
        intent: .browse
      ),
      session: root(id)
    )
    state.composer.draft = draft
    state.composer.revision = draft.isEmpty ? 0 : 1
    state.composer.contentRevision = draft.isEmpty ? 0 : 1
    state.composer.contentUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    return state
  }

  private func app(
    session: SessionFeature.State?,
    sessions: [OpenCodeSession]? = nil
  ) -> AppFeature.State {
    let server = server()
    let home = HomeFeature.State(
      server: server,
      sessions: sessions ?? [root("a"), root("b")],
      hasLoaded: true
    )
    let connection = ConnectionFeature.State(id: 1, server: server, phase: .connected)
    return AppFeature.State(
      connection: connection,
      home: home,
      session: session,
      savedServer: server,
      savedServers: [server],
      savedData: .read
    )
  }

  private func makeStore(
    _ state: AppFeature.State,
    backend: DraftBackend
  ) -> TestStoreOf<AppFeature> {
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = SharedStore(
        defaults: OpenCodeCore.InMemoryStorage(),
        keychain: OpenCodeCore.InMemoryStorage()
      )
      $0.networkPath = NetworkPathClient(
        current: { .online },
        updates: { AsyncStream { $0.finish() } },
        waitUntilAvailable: {}
      )
      $0.openCodeClient = .testValue
      $0.composerDrafts = client(backend)
      $0.uuidClient = .incrementing()
    }
    store.exhaustivity = .off
    return store
  }

  private func settle(_ store: TestStoreOf<AppFeature>) async {
    for _ in 0..<12 {
      await store.finish()
      await store.skipReceivedActions(strict: false)
    }
  }

  private func pump(
    _ store: TestStoreOf<AppFeature>,
    timeout: Duration = .seconds(2),
    until condition: @escaping () async -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      await store.skipReceivedActions(strict: false)
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
  }

  @Test("Done waits for the explicit draft save, with no timer")
  func dismissalWaitsForSave() async {
    let backend = DraftBackend()
    let gate = SaveGate()
    await backend.setGate(gate)
    let initial = app(session: session(draft: "Dismiss draft"))
    let store = makeStore(initial, backend: backend)

    await store.send(.session(.delegate(.dismiss)))
    #expect(await pump(store) { store.state.pendingDismissal != nil })
    try? await Task.sleep(for: .milliseconds(250))
    #expect(store.state.session != nil)
    #expect(store.state.pendingDismissal != nil)

    await gate.releaseAll()
    #expect(await pump(store, timeout: .seconds(3)) { store.state.session == nil })
    let key = ComposerDraftKey(serverID: server().persistenceID, scope: .session("a"))
    #expect(await backend.stored(key)?.text == "Dismiss draft")
  }

  @Test("a failed dismissal save keeps the session and surfaces a notice")
  func dismissalSaveFailure() async {
    let backend = DraftBackend()
    await backend.setFailure(true)
    let store = makeStore(app(session: session(draft: "Keep open")), backend: backend)

    await store.send(.session(.delegate(.dismiss)))
    await settle(store)
    #expect(store.state.session != nil)
    #expect(store.state.pendingDismissal == nil)
    #expect(store.state.notice == .couldNotSaveDraft)
  }

  @Test("a late dismissal completion cannot close a newly opened session")
  func lateDismissalIsFenced() async {
    let backend = DraftBackend()
    let gate = SaveGate()
    await backend.setGate(gate)
    let first = session("a", draft: "A draft")
    let store = makeStore(app(session: first), backend: backend)

    await store.send(.session(.delegate(.dismiss)))
    #expect(await pump(store) { store.state.pendingDismissal != nil })

    let selection = SessionSelection(
      serverID: server().persistenceID,
      sessionID: "b",
      intent: .browse
    )
    await store.send(.home(.delegate(.openSession(selection))))
    #expect(await pump(store) { store.state.session?.selection.sessionID == "b" })
    #expect(store.state.pendingDismissal == nil)

    await gate.releaseAll()
    await settle(store)
    #expect(store.state.session?.selection.sessionID == "b")
    #expect(store.state.session?.root?.id == "b")
  }


  @Test("a create that succeeds after the session was replaced never dispatches its prompt")
  func cancelledCreateDoesNotPrompt() async {
    let gate = SaveGate()
    let createCalls = Mutex(0)
    let promptCalls = Mutex(0)
    let client = OpenCodeClient(
      health: { _ in throw OpenCodeClientError(.unsupported) },
      redeemPairing: { _ in throw OpenCodeClientError(.unsupported) },
      projects: { _ in [] },
      sessionPage: { _, _, _ in SessionPage(sessions: []) },
      getSession: { _, id in
        OpenCodeSession(
          id: id, serverTitle: id, projectID: "p1", directory: "/work/opencode",
          updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
      },
      activeSessionIDs: { _ in [] },
      interruptSession: { _, _ in true },
      sessionIsActive: { _, _ in false },
      pendingRequests: { _, _, _ in PendingRequests() },
      pendingInputs: { _, _ in [] },
      sendPrompt: { _, _, _ in promptCalls.withLock { $0 += 1 } },
      createSession: { _, directory, id in
        createCalls.withLock { $0 += 1 }
        await gate.wait()
        return OpenCodeSession(
          id: id,
          serverTitle: "New",
          projectID: "p1",
          directory: directory,
          updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
      },
      waitForIdle: { _, _ in },
      events: { _, _ in AsyncThrowingStream { $0.finish() } }
    )
    let backend = DraftBackend()
    let initial = app(session: nil, sessions: [root("b")])
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = SharedStore(
        defaults: OpenCodeCore.InMemoryStorage(),
        keychain: OpenCodeCore.InMemoryStorage()
      )
      $0.networkPath = NetworkPathClient(
        current: { .online },
        updates: { AsyncStream { $0.finish() } },
        waitUntilAvailable: {}
      )
      $0.openCodeClient = client
      $0.composerDrafts = self.client(backend)
      $0.uuidClient = .incrementing()
    }
    store.exhaustivity = .off

    await store.send(.home(.delegate(.newSession(directory: "/work/opencode"))))
    _ = await pump(store) { store.state.session != nil }
    await store.send(.session(.composer(.textChanged("Creates then navigates"))))
    await store.send(.session(.composer(.sendTapped)))
    #expect(await pump(store) { createCalls.withLock { $0 } == 1 })

    let selection = SessionSelection(
      serverID: server().persistenceID, sessionID: "b", intent: .browse
    )
    await store.send(.home(.delegate(.openSession(selection))))
    #expect(await pump(store) { store.state.session?.selection.sessionID == "b" })
    await gate.releaseAll()
    try? await Task.sleep(for: .milliseconds(100))
    await store.skipReceivedActions(strict: false)
    #expect(promptCalls.withLock { $0 } == 0)
  }


  @Test("disconnect transfers the unsaved composer before the child disappears")
  func disconnectTransfersDraft() async {
    let backend = DraftBackend()
    let store = makeStore(app(session: session("a", draft: "Before disconnect")), backend: backend)
    await store.send(.home(.delegate(.disconnect)))
    await settle(store)
    #expect(store.state.session == nil)
    let key = ComposerDraftKey(serverID: server().persistenceID, scope: .session("a"))
    #expect(await backend.stored(key)?.text == "Before disconnect")
  }


  @Test("switching servers transfers the unsaved composer before the connection changes")
  func switchServerTransfersDraft() async {
    let backend = DraftBackend()
    let store = makeStore(app(session: session("a", draft: "Before switch")), backend: backend)
    let other = OpenCodeServer(
      url: "http://127.0.0.1:4111",
      username: "opencode",
      password: "other-token"
    )
    await store.send(.home(.delegate(.switchServer(other))))
    await settle(store)
    let key = ComposerDraftKey(serverID: server().persistenceID, scope: .session("a"))
    #expect(await backend.stored(key)?.text == "Before switch")
    #expect(store.state.session == nil)
  }


  @Test("a failed replacement transfer keeps the departing draft and a retry saves it")
  func replacementFailureRetainsDraft() async {
    let backend = DraftBackend()
    await backend.setFailure(true)
    let store = makeStore(app(session: session("a", draft: "Replace me")), backend: backend)
    let key = ComposerDraftKey(serverID: server().persistenceID, scope: .session("a"))
    let selection = SessionSelection(
      serverID: server().persistenceID,
      sessionID: "b",
      intent: .browse
    )

    await store.send(.home(.delegate(.openSession(selection))))
    await settle(store)
    #expect(store.state.session?.selection.sessionID == "b")
    #expect(store.state.retainedDraftTransfers[key]?.draft.text == "Replace me")
    #expect(store.state.notice == .draftKept)
    #expect(await backend.stored(key) == nil)

    await backend.setFailure(false)
    await store.send(.retryRetainedDrafts)
    await settle(store)
    #expect(store.state.retainedDraftTransfers.isEmpty)
    #expect(store.state.notice == nil)
    #expect(await backend.stored(key)?.text == "Replace me")
  }

  @Test("a failed server-switch transfer retains the draft until a retry saves it")
  func switchServerFailureRetainsDraft() async {
    let backend = DraftBackend()
    await backend.setFailure(true)
    let store = makeStore(app(session: session("a", draft: "Before switch")), backend: backend)
    let key = ComposerDraftKey(serverID: server().persistenceID, scope: .session("a"))
    let other = OpenCodeServer(
      url: "http://127.0.0.1:4111",
      username: "opencode",
      password: "other-token"
    )

    await store.send(.home(.delegate(.switchServer(other))))
    await settle(store)
    #expect(store.state.session == nil)
    #expect(store.state.retainedDraftTransfers[key]?.draft.text == "Before switch")
    #expect(store.state.notice == .draftKept)

    await backend.setFailure(false)
    await store.send(.retryRetainedDrafts)
    await settle(store)
    #expect(store.state.retainedDraftTransfers.isEmpty)
    #expect(await backend.stored(key)?.text == "Before switch")
  }

  @Test("a failed disconnect transfer retains the draft until a retry saves it")
  func disconnectFailureRetainsDraft() async {
    let backend = DraftBackend()
    await backend.setFailure(true)
    let store = makeStore(app(session: session("a", draft: "Before disconnect")), backend: backend)
    let key = ComposerDraftKey(serverID: server().persistenceID, scope: .session("a"))

    await store.send(.home(.delegate(.disconnect)))
    await settle(store)
    #expect(store.state.session == nil)
    #expect(store.state.retainedDraftTransfers[key]?.draft.text == "Before disconnect")
    #expect(store.state.notice == .draftKept)

    await backend.setFailure(false)
    await store.send(.retryRetainedDrafts)
    await settle(store)
    #expect(store.state.retainedDraftTransfers.isEmpty)
    #expect(await backend.stored(key)?.text == "Before disconnect")
  }

  @Test("a failed interactive dismissal retains the draft until a retry saves it")
  func interactiveDismissalFailureRetainsDraft() async {
    let backend = DraftBackend()
    await backend.setFailure(true)
    let store = makeStore(app(session: session("a", draft: "Swipe away")), backend: backend)
    let key = ComposerDraftKey(serverID: server().persistenceID, scope: .session("a"))

    await store.send(.sessionDestinationDismissed)
    await settle(store)
    #expect(store.state.session == nil)
    #expect(store.state.retainedDraftTransfers[key]?.draft.text == "Swipe away")
    #expect(store.state.notice == .draftKept)

    await backend.setFailure(false)
    await store.send(.retryRetainedDrafts)
    await settle(store)
    #expect(store.state.retainedDraftTransfers.isEmpty)
    #expect(await backend.stored(key)?.text == "Swipe away")
  }


  @Test("returning to a session retries a retained draft and restores it in the composer")
  func retainedDraftRestoresAfterReturn() async {
    let backend = DraftBackend()
    await backend.setFailure(true)
    let store = makeStore(app(session: session("a", draft: "Keep me")), backend: backend)
    let key = ComposerDraftKey(serverID: server().persistenceID, scope: .session("a"))
    let selectionB = SessionSelection(
      serverID: server().persistenceID,
      sessionID: "b",
      intent: .browse
    )

    await store.send(.home(.delegate(.openSession(selectionB))))
    await settle(store)
    #expect(store.state.retainedDraftTransfers[key]?.draft.text == "Keep me")

    await backend.setFailure(false)
    let selectionA = SessionSelection(
      serverID: server().persistenceID,
      sessionID: "a",
      intent: .browse
    )
    await store.send(.home(.delegate(.openSession(selectionA))))
    #expect(await pump(store, timeout: .seconds(3)) {
      store.state.session?.composer.draft == "Keep me"
    })
    #expect(await backend.stored(key)?.text == "Keep me")
    #expect(store.state.retainedDraftTransfers.isEmpty)
  }

  @Test("an older transfer cannot overwrite newer typing after returning to the session")
  func olderTransferCannotOverwriteNewerTyping() async {
    let backend = DraftBackend()
    let saveQueue = SaveQueue()
    let transferQueue = SaveQueue()
    await backend.setSaveQueue(saveQueue)
    await backend.setTransferQueue(transferQueue)
    let store = makeStore(app(session: session("a", draft: "Old A")), backend: backend)
    let key = ComposerDraftKey(serverID: server().persistenceID, scope: .session("a"))
    let selectionB = SessionSelection(
      serverID: server().persistenceID,
      sessionID: "b",
      intent: .browse
    )

    await store.send(.home(.delegate(.openSession(selectionB))))
    #expect(await pump(store) { store.state.session?.selection.sessionID == "b" })
    #expect(await pump(store) { await transferQueue.attempts >= 1 })

    let selectionA = SessionSelection(
      serverID: server().persistenceID,
      sessionID: "a",
      intent: .browse
    )
    await store.send(.home(.delegate(.openSession(selectionA))))
    #expect(await pump(store) { store.state.session?.selection.sessionID == "a" })
    await store.send(.session(.composer(.textChanged("Newer A"))))
    await store.send(.session(.composer(.flush)))
    #expect(await pump(store) { await saveQueue.attempts >= 1 })
    await saveQueue.releaseAll()
    #expect(await pump(store) { await backend.stored(key)?.text == "Newer A" })

    await transferQueue.releaseAll()
    await settle(store)
    #expect(await backend.stored(key)?.text == "Newer A")
    #expect(store.state.session?.selection.sessionID == "a")
  }

  @Test("Done saves newer content before dismissing")
  func doneWaitsForNewerContent() async {
    let backend = DraftBackend()
    let queue = SaveQueue()
    await backend.setSaveQueue(queue)
    let store = makeStore(app(session: session("a", draft: "Draft A")), backend: backend)
    let key = ComposerDraftKey(serverID: server().persistenceID, scope: .session("a"))

    await store.send(.session(.delegate(.dismiss)))
    #expect(await pump(store) { await queue.attempts >= 1 })
    await store.send(.session(.composer(.textChanged("Draft B"))))

    await queue.releaseNext()
    #expect(await pump(store, timeout: .seconds(3)) { await queue.attempts >= 2 })
    #expect(store.state.session != nil)
    #expect(store.state.pendingDismissal != nil)

    await queue.releaseAll()
    #expect(await pump(store, timeout: .seconds(3)) { store.state.session == nil })
    #expect(await backend.stored(key)?.text == "Draft B")
  }

  @Test("opening another session transfers the replaced session draft")
  func replacementTransfersDraft() async {
    let backend = DraftBackend()
    let store = makeStore(app(session: session("a", draft: "Replace me")), backend: backend)
    let selection = SessionSelection(
      serverID: server().persistenceID,
      sessionID: "b",
      intent: .browse
    )
    await store.send(.home(.delegate(.openSession(selection))))
    await settle(store)
    let oldKey = ComposerDraftKey(serverID: server().persistenceID, scope: .session("a"))
    #expect(await backend.stored(oldKey)?.text == "Replace me")
    #expect(store.state.session?.selection.sessionID == "b")
  }
}
