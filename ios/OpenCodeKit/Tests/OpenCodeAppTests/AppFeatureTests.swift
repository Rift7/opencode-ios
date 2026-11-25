import ComposableArchitecture
import Foundation
import OpenCodeApp
import OpenCodeCore
import OpenCodeDrawer
import OpenCodeServer
import OpenCodeSession
import OpenCodeTestSupport
import Synchronization
import Testing

@MainActor
@Suite("App feature")
struct AppFeatureTests {
  private func storage(
    defaults: OpenCodeCore.InMemoryStorage = OpenCodeCore.InMemoryStorage(),
    keychain: any KeyValueStorage = OpenCodeCore.InMemoryStorage()
  ) -> SharedStore {
    SharedStore(defaults: defaults, keychain: keychain)
  }

  private func pinnedState(
    _ state: AppFeature.State = AppFeature.State()
  ) -> AppFeature.State {
    var copy = state
    copy.isPinnedForUITest = true
    return copy
  }

  @Test("first launch restores nothing and waits for a server")
  func missingRestoreIsDisconnected() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = self.storage()
      $0.networkPath = self.quietPath()
    }

    await store.send(.task)
    await store.receive(.restored(.missing)) {
      $0.restore = .ready
      $0.savedData = .read
    }
  }

  @Test("a damaged saved server is corrupt data, not an empty install")
  func corruptSavedServer() {
    let keychain = OpenCodeCore.InMemoryStorage()
    _ = keychain.write(Data("not json".utf8), for: ServerSharedKeys.savedServer.name)
    let store = storage(keychain: keychain)

    #expect(AppRestoreResult.read(store) == .corrupt)
  }

  @Test("a denied keychain is unavailable, not missing, and does not discard state")
  func unavailableStorage() async {
    let store = TestStore(
      initialState: AppFeature.State(savedServer: TestServer.server)
    ) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = self.storage(keychain: FailingStorage(failure: .denied))
      $0.networkPath = self.quietPath()
    }

    await store.send(.task)
    await store.receive(.restored(.storageUnavailable(.denied))) {
      $0.restore = .storageUnavailable(.denied)
      $0.savedData = .unreadable(.storage(.denied))
    }
    #expect(store.state.savedServer == TestServer.server)
  }



  @Test("the shell forwards queues, durable boundaries, reverts, shells and jobs to the session")
  func sessionEventForwarding() async {
    let server = TestServer.server
    let root = OpenCodeSession(
      id: "root",
      serverTitle: "Root",
      projectID: "p1",
      directory: "/work/opencode",
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let selection = SessionSelection(
      serverID: server.persistenceID,
      sessionID: "root",
      intent: .browse
    )
    var session = SessionFeature.State(
      id: 1,
      server: server,
      selection: selection,
      session: root
    )
    session.isLive = true
    let home = HomeFeature.State(server: server, sessions: [root], hasLoaded: true)
    let connection = ConnectionFeature.State(id: 1, server: server, phase: .connected)
    let app = AppFeature.State(connection: connection, home: home, session: session)
    let clientCalls = CallCounter()
    let client = OpenCodeClient(
      health: { _ in throw OpenCodeClientError(.unsupported) },
      redeemPairing: { _ in throw OpenCodeClientError(.unsupported) },
      projects: { _ in [] },
      sessionPage: { _, _, _ in SessionPage(sessions: []) },
      getSession: { _, _ in
        _ = clientCalls.next()
        return root
      },
      activeSessionIDs: { _ in [] },
      sessionIsActive: { _, _ in false },
      pendingInputs: { _, _ in
        [PendingInput(id: "steer-1", text: "keep going", delivery: .steer)]
      },
      transcript: { _, _, _ in
        TranscriptPage(
          items: [.assistantMarkdown(id: "m1-text-0", text: "done", inProgress: false)]
        )
      },
      events: { _, _ in AsyncThrowingStream { $0.finish() } }
    )
    let store = TestStore(initialState: app) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = self.storage()
      $0.networkPath = self.quietPath()
      $0.openCodeClient = client
      $0.clock = .testValue
    }
    store.exhaustivity = .off
    let token = ConnectionFeature.Token(attempt: 1_000, stream: 0)
    let shell = ServerShell(id: "shell-1", command: "swift test", sessionID: "root")

    await store.send(.connection(.streamEvent(token: token, event: .shellStarted(shell))))
    await settle(store)
    #expect(store.state.session?.background.shells.map(\.id) == ["shell-1"])

    let job = ServerJob(id: "job-1", kind: .codemode, sessionID: "root", isRunning: true)
    await store.send(.connection(.streamEvent(token: token, event: .jobUpdated(job))))
    await settle(store)
    #expect(store.state.session?.background.jobs.map(\.id) == ["job-1"])

    await store.send(
      .connection(
        .streamEvent(token: token, event: .inputQueueChanged(sessionID: "root", inputID: "steer-1"))
      )
    )
    await settle(store)
    #expect(store.state.session?.pendingInputs.map(\.id) == ["steer-1"])

    let before = clientCalls.count
    await store.send(
      .connection(
        .streamEvent(
          token: token,
          event: .contentBatch(
            sessionID: "root",
            events: [.textEnded(messageID: "m1", ordinal: 0, text: "done")]
          )
        )
      )
    )
    await settle(store)
    #expect(clientCalls.count > before)
    #expect(
      store.state.session?.transcripts["root"]?.items.contains(where: { $0.id == "m1-text-0" }) == true
    )

    await store.send(
      .connection(
        .streamEvent(token: token, event: .revertChanged(sessionID: "root", messageID: "m1", committed: false))
      )
    )
    await settle(store)
    #expect(store.state.session?.root?.revertMessageID == "m1")

    await store.send(
      .connection(.streamEvent(token: token, event: .shellEnded(shellID: "shell-1")))
    )
    await settle(store)
    #expect(store.state.session?.background.shells.isEmpty == true)
  }

  @Test("opening a session creates the child and a replacement gets a new identity")
  func sessionOwnership() async {
    let home = HomeFeature.State(
      server: TestServer.server,
      sessions: [
        OpenCodeSession(
          id: "a", serverTitle: "A", projectID: "p1", directory: "/work/opencode",
          updatedAt: Date(timeIntervalSince1970: 1_700_000_000)),
        OpenCodeSession(
          id: "b", serverTitle: "B", projectID: "p1", directory: "/work/opencode",
          updatedAt: Date(timeIntervalSince1970: 1_700_000_100)),
      ],
      hasLoaded: true
    )
    let store = TestStore(
      initialState: AppFeature.State(home: home)
    ) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = self.storage()
      $0.networkPath = self.quietPath()
      $0.openCodeClient = .testValue
    }
    store.exhaustivity = .off

    let first = SessionSelection(
      serverID: TestServer.server.persistenceID, sessionID: "a", intent: .catchUpCard
    )
    await store.send(.home(.delegate(.openSession(first))))
    let firstID = store.state.session?.id
    #expect(firstID != nil)
    #expect(store.state.session?.selection.intent == .catchUpCard)
    #expect(store.state.session?.root?.id == "a")

    let second = SessionSelection(
      serverID: TestServer.server.persistenceID, sessionID: "b", intent: .browse
    )
    await store.send(.home(.delegate(.openSession(second))))
    #expect(store.state.session?.id != firstID)
    #expect(store.state.session?.root?.id == "b")
    #expect(store.state.sessionDestination == second)

    await store.send(.sessionDestinationDismissed)
    #expect(store.state.session == nil)
    #expect(store.state.sessionDestination == nil)
  }

  @Test("a selection from another server cannot open a session here")
  func sessionServerIsolation() async {
    let home = HomeFeature.State(server: TestServer.server, hasLoaded: true)
    let store = TestStore(initialState: AppFeature.State(home: home)) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = self.storage()
      $0.networkPath = self.quietPath()
      $0.openCodeClient = .testValue
    }
    store.exhaustivity = .off

    await store.send(
      .home(
        .delegate(
          .openSession(
            SessionSelection(
              serverID: TestServer.other.persistenceID,
              sessionID: "a",
              intent: .browse
            )
          )
        )
      )
    )
    #expect(store.state.session == nil)
  }

  @Test("a valid saved server and its launch cache restore together")
  func restoredServerAndCache() {
    let store = storage()
    #expect(store.write(TestServer.server, for: ServerSharedKeys.savedServer) == .success)
    #expect(store.write([TestServer.server], for: ServerSharedKeys.savedServers) == .success)
    let cache = CachedServerSummary(
      projects: TestServer.projects,
      version: TestServer.info.version,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    #expect(
      store.write(
        [TestServer.server.persistenceID: cache],
        for: ServerSharedKeys.cachedSummaries
      ) == .success
    )

    #expect(
      AppRestoreResult.read(store)
        == .restored(
          server: TestServer.server,
          servers: [TestServer.server],
          cache: cache,
          notice: nil
        )
    )
  }

  @Test("a corrupt credential key is reported even when the list is readable")
  func partialCorruptCredentials() {
    let keychain = OpenCodeCore.InMemoryStorage()
    _ = keychain.write(Data("not json".utf8), for: ServerSharedKeys.savedServer.name)
    let shared = storage(keychain: keychain)
    #expect(shared.write([TestServer.server], for: ServerSharedKeys.savedServers) == .success)

    let result = AppRestoreResult.read(shared)
    guard case .restored(let server, let servers, _, let notice) = result else {
      Issue.record("expected a usable list beside the corrupt key")
      return
    }
    #expect(server == TestServer.server)
    #expect(servers == [TestServer.server])
    #expect(notice == .couldNotReadSavedServers)
  }

  @Test("restoring a usable list with one corrupt key still requires explicit recovery")
  func partialCorruptRestoreKeepsWarning() async {
    var state = AppFeature.State()
    state.isPinnedForUITest = true
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = self.storage()
    }

    await store.send(
      .restored(
        .restored(
          server: TestServer.server,
          servers: [TestServer.server],
          cache: nil,
          notice: .couldNotReadSavedServers
        )
      )
    ) {
      $0.restore = .ready
      $0.savedData = .unreadable(.corrupt)
      $0.notice = .couldNotReadSavedServers
      $0.savedServer = TestServer.server
      $0.savedServers = [TestServer.server]
      $0.connection = ConnectionFeature.State(
        id: 1,
        server: TestServer.server,
        phase: .connecting,
        isPinned: true
      )
    }
    await store.receive(.connection(.task))
  }

  @Test("restoring a saved server opens a connection with its cached projects")
  func restoreCreatesConnection() async {
    let state = pinnedState(AppFeature.State())
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = self.storage()
      $0.networkPath = self.quietPath()
    }

    let cache = CachedServerSummary(
      projects: TestServer.projects,
      version: TestServer.info.version,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    await store.send(
      .restored(.restored(server: TestServer.server, servers: [TestServer.server], cache: cache, notice: nil))
    ) {
      $0.restore = .ready
      $0.savedData = .read
      $0.savedServer = TestServer.server
      $0.savedServers = [TestServer.server]
      $0.connection = ConnectionFeature.State(
        id: 1,
        server: TestServer.server,
        phase: .connecting,
        projects: TestServer.projects,
        isPinned: true
      )
    }
    await store.receive(.connection(.task))
  }

  @Test("a verified connection is persisted and a write failure is reported")
  func verifiedConnectionPersistence() async {
    let keychain = OpenCodeCore.InMemoryStorage()
    let shared = storage(keychain: keychain)
    var state = AppFeature.State()
    state.isPinnedForUITest = true
    state.savedData = .read
    state.connection = ConnectionFeature.State(
      id: 1,
      server: TestServer.server,
      phase: .connected,
      projects: [],
      isPinned: true
    )
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = shared
    }

    await store.send(.connection(.delegate(.verified(TestServer.server, TestServer.info)))) {
      $0.savedServer = TestServer.server
      $0.savedServers = [TestServer.server]
    }
    await store.receive(.persisted(.success(.init(server: TestServer.server, servers: [TestServer.server]))))

    #expect(shared.result(ServerSharedKeys.savedServer) == .success(TestServer.server))
    #expect(shared.result(ServerSharedKeys.savedServers) == .success([TestServer.server]))
  }

  @Test("a keychain write failure keeps the connection and reports the explicit outcome")
  func failedPersistenceIsReported() async {
    let shared = storage(keychain: FailingStorage(failure: .unavailable))
    var state = AppFeature.State()
    state.isPinnedForUITest = true
    state.savedData = .read
    state.connection = ConnectionFeature.State(
      id: 1,
      server: TestServer.server,
      phase: .connected,
      projects: [],
      isPinned: true
    )
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = shared
    }

    await store.send(.connection(.delegate(.verified(TestServer.server, TestServer.info)))) {
      $0.savedServer = TestServer.server
      $0.savedServers = [TestServer.server]
    }
    await store.receive(.persisted(.failure(.storage(.unavailable)))) {
      $0.notice = .couldNotSaveServer(.unavailable)
    }
  }

  @Test("re-connecting keeps a saved server's local name")
  func verifiedConnectionKeepsLocalName() async {
    let shared = storage()
    var saved = TestServer.server
    saved.name = "Desk"
    var state = AppFeature.State(savedServer: saved, savedServers: [saved], savedData: .read)
    state.isPinnedForUITest = true
    state.connection = ConnectionFeature.State(
      id: 1,
      server: TestServer.server,
      phase: .connected,
      projects: [],
      isPinned: true
    )
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = shared
    }

    store.exhaustivity = .off
    await store.send(.connection(.delegate(.verified(TestServer.server, TestServer.info))))
    await settle(store)
    #expect(store.state.savedServer?.name == "Desk")
    #expect(shared.result(ServerSharedKeys.savedServer) == .success(store.state.savedServer))
  }

  @Test("a manual address without a scheme becomes HTTP and blank username stays opencode")
  func manualFormDefaults() async {
    var state = AppFeature.State()
    state.isPinnedForUITest = true
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = self.storage()
    }

    await store.send(.manualEntryTapped) {
      $0.form = ServerForm()
    }
    await store.send(.formAddressChanged("laptop.local:4096")) {
      $0.form?.address = "laptop.local:4096"
    }
    await store.send(.formUsernameChanged("")) {
      $0.form?.username = ""
    }
    await store.send(.formSubmitted) {
      $0.form = nil
      $0.connection = ConnectionFeature.State(
        id: 1,
        server: OpenCodeServer(
          url: "http://laptop.local:4096",
          username: "opencode",
          password: "",
          name: nil
        ),
        phase: .connecting,
        isPinned: true
      )
    }
  }

  @Test("an invalid address stays in the form with a typed problem")
  func invalidAddress() async {
    var state = AppFeature.State()
    state.isPinnedForUITest = true
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = self.storage()
    }

    await store.send(.manualEntryTapped) { $0.form = ServerForm() }
    await store.send(.formAddressChanged("ftp://laptop.local")) {
      $0.form?.address = "ftp://laptop.local"
    }
    await store.send(.formSubmitted) {
      $0.form?.problem = .invalidAddress(.badScheme)
    }
  }

  @Test("a blank address is reported without an empty connection")
  func blankAddress() async {
    var state = AppFeature.State()
    state.isPinnedForUITest = true
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = self.storage()
    }

    await store.send(.manualEntryTapped) { $0.form = ServerForm() }
    await store.send(.formSubmitted) {
      $0.form?.problem = .emptyAddress
    }
    #expect(store.state.connection == nil)
  }

  @Test("opening a pairing link waits for confirmation and never redeems")
  func deepLinkNeedsConfirmation() async {
    let script = ScriptedClient(
      health: Script([.success(TestServer.info)]),
      projects: Script([.success([])])
    )
    var state = AppFeature.State()
    state.isPinnedForUITest = true
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.openCodeClient = script.client()
      $0.sharedStore = self.storage()
      $0.uuidClient = UuidClient.incrementing()
    }

    let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    let link = PairingLink(
      origin: "https://studio.invalid",
      code: "Pair-123_xyz",
      alternateOrigins: ["https://studio.ts.net"]
    )
    await store.send(.openURL(link.deepLinkURL)) {
      $0.pendingPairing = PairingConfirmation(id: id, link: link)
    }

    #expect(script.redeemCalls.count == 0)
  }

  @Test("confirming a pairing link redeems it exactly once and connects")
  func confirmsPairing() async {
    let script = ScriptedClient(
      health: Script([.success(TestServer.info)]),
      projects: Script([.success([])])
    )
    var state = AppFeature.State()
    state.isPinnedForUITest = true
    let link = PairingLink(origin: "https://studio.invalid", code: "Pair-123_xyz")
    state.pendingPairing = PairingConfirmation(
      id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
      link: link
    )
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.openCodeClient = script.client()
      $0.sharedStore = self.storage()
    }

    await store.send(.pairingConfirmed(state.pendingPairing!.id)) {
      $0.pendingPairing = nil
      $0.pairingAttempt = PairingAttempt(id: 1, link: link)
    }
    await store.receive(.pairingFinished(attempt: 1, result: .success(TestServer.server))) {
      $0.pairingAttempt = nil
      $0.connection = ConnectionFeature.State(
        id: 1,
        server: TestServer.server,
        phase: .connecting,
        isPinned: true
      )
    }

    #expect(script.redeemCalls.count == 1)
  }

  @Test("pasting a pairing link is an explicit action and redeems it")
  func pastesPairing() async {
    let script = ScriptedClient(
      health: Script([.success(TestServer.info)]),
      projects: Script([.success([])])
    )
    var state = AppFeature.State()
    state.isPinnedForUITest = true
    let link = PairingLink(origin: "https://studio.invalid", code: "Pair-123_xyz")
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.openCodeClient = script.client()
      $0.sharedStore = self.storage()
      $0.pasteboard = PasteboardClient(string: { link.deepLinkURL })
    }

    await store.send(.pastePairingTapped) {
      $0.pairingAttempt = PairingAttempt(id: 1, link: link)
      $0.connection = nil
    }
    await store.receive(.pairingFinished(attempt: 1, result: .success(TestServer.server))) {
      $0.pairingAttempt = nil
      $0.connection = ConnectionFeature.State(
        id: 1,
        server: TestServer.server,
        phase: .connecting,
        isPinned: true
      )
    }
    #expect(script.redeemCalls.count == 1)
  }

  @Test("an empty clipboard is reported beside Paste")
  func emptyClipboard() async {
    var state = AppFeature.State()
    state.isPinnedForUITest = true
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = self.storage()
      $0.pasteboard = PasteboardClient(string: { nil })
    }

    await store.send(.pastePairingTapped) {
      $0.pasteProblem = .emptyClipboard
    }
  }

  @Test("a loopback pairing link is refused before any network attempt")
  func loopbackPairing() async {
    let script = ScriptedClient(
      health: Script([.success(TestServer.info)]),
      projects: Script([.success([])])
    )
    var state = AppFeature.State()
    state.isPinnedForUITest = true
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.openCodeClient = script.client()
      $0.sharedStore = self.storage()
      $0.pasteboard = PasteboardClient(string: {
        #"{"code":"Pair-123_xyz","urls":["http://127.0.0.1:4096"]}"#
      })
    }

    await store.send(.pastePairingTapped) {
      $0.pasteProblem = .loopback
    }
    #expect(script.redeemCalls.count == 0)
  }

  @Test("an expired pairing code keeps its typed reason")
  func expiredPairing() async {
    let script = ScriptedClient(
      health: Script([.success(TestServer.info)]),
      projects: Script([.success([])]),
      redeem: .failure(OpenCodeClientError(.pairingExpired))
    )
    var state = AppFeature.State()
    state.isPinnedForUITest = true
    let link = PairingLink(origin: "https://studio.invalid", code: "Pair-123_xyz")
    state.pairingAttempt = PairingAttempt(id: 1, link: link)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.openCodeClient = script.client()
      $0.sharedStore = self.storage()
    }

    await store.send(
      .pairingFinished(attempt: 1, result: .failure(OpenCodeClientError(.pairingExpired)))
    ) {
      $0.pairingAttempt = nil
      $0.pairingProblem = .expired
    }
  }

  @Test("a manual form entry that is a pairing link pairs instead of using the address")
  func manualPairingLink() async {
    let script = ScriptedClient(
      health: Script([.success(TestServer.info)]),
      projects: Script([.success([])])
    )
    var state = AppFeature.State()
    state.isPinnedForUITest = true
    state.form = ServerForm(address: "https://studio.invalid/auth/connect/Pair-123_xyz")
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.openCodeClient = script.client()
      $0.sharedStore = self.storage()
    }

    await store.send(.formSubmitted) {
      $0.form = nil
      $0.pairingAttempt = PairingAttempt(
        id: 1,
        link: PairingLink(origin: "https://studio.invalid", code: "Pair-123_xyz")
      )
      $0.connection = nil
    }
    await store.receive(.pairingFinished(attempt: 1, result: .success(TestServer.server))) {
      $0.pairingAttempt = nil
      $0.connection = ConnectionFeature.State(
        id: 1,
        server: TestServer.server,
        phase: .connecting,
        isPinned: true
      )
    }
    #expect(script.redeemCalls.count == 1)
  }

  @Test("a stale pairing result cannot replace the current attempt")
  func stalePairingResult() async {
    let script = ScriptedClient(
      health: Script([.success(TestServer.info)]),
      projects: Script([.success([])])
    )
    var state = AppFeature.State()
    state.isPinnedForUITest = true
    state.pairingAttempt = PairingAttempt(
      id: 2,
      link: PairingLink(origin: "https://studio.invalid", code: "Pair-123_xyz")
    )
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.openCodeClient = script.client()
      $0.sharedStore = self.storage()
    }

    await store.send(
      .pairingFinished(attempt: 1, result: .success(TestServer.server))
    )
    #expect(store.state.pairingAttempt?.id == 2)
    #expect(store.state.connection == nil)
  }

  @Test("disconnecting closes the connection but keeps saved credentials")
  func disconnectKeepsSavedServer() async {
    var state = AppFeature.State()
    state.isPinnedForUITest = true
    state.savedServer = TestServer.server
    state.savedServers = [TestServer.server]
    state.connection = ConnectionFeature.State(
      id: 1,
      server: TestServer.server,
      phase: .connected,
      projects: TestServer.projects,
      isPinned: true
    )
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = self.storage()
    }

    await store.send(.disconnectTapped) {
      $0.connection = nil
    }
    #expect(store.state.savedServer == TestServer.server)
    #expect(store.state.savedServers == [TestServer.server])
  }

  @Test("forgetting damaged saved data clears both launch keys")
  func forgetSavedServers() async {
    let shared = storage()
    #expect(shared.write(TestServer.server, for: ServerSharedKeys.savedServer) == .success)
    #expect(shared.write([TestServer.server], for: ServerSharedKeys.savedServers) == .success)
    let state = pinnedState(AppFeature.State(savedServer: TestServer.server, savedServers: [TestServer.server]))
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = shared
    }

    await store.send(.forgetSavedServersTapped)
    await store.receive(.savedServersForgotten(.success(.init(server: nil, servers: [])))) {
      $0.savedServer = nil
      $0.savedServers = []
      $0.savedData = .read
      $0.restore = .ready
      $0.connection = nil
      $0.home = nil
      $0.session = nil
      $0.sessionDestination = nil
    }
    #expect(shared.read(ServerSharedKeys.savedServer).isMissing)
    #expect(shared.read(ServerSharedKeys.savedServers).isMissing)
  }

  @Test("a scene change reaches the connection's cancellation boundary")
  func scenePhaseForwarding() async {
    var state = AppFeature.State()
    state.isPinnedForUITest = true
    state.connection = ConnectionFeature.State(
      id: 1,
      server: TestServer.server,
      phase: .connected,
      projects: TestServer.projects,
      isPinned: true
    )
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = self.storage()
    }

    await store.send(.scenePhaseChanged(isActive: false)) {
      $0.isInForeground = false
    }
    await store.receive(.connection(.scenePhaseChanged(isActive: false))) {
      $0.connection?.isInForeground = false
    }
  }

  @Test("a manual connection does not overwrite an unreadable saved list")
  func manualConnectionPreservesUnreadableList() async {
    let keychain = ToggleStorage(failing: true)
    let shared = storage(keychain: keychain)
    let oldFirst = OpenCodeServer(url: "http://10.0.0.2:4096", password: "old-one")
    let oldSecond = OpenCodeServer(url: "http://10.0.0.3:4096", password: "old-two")

    var state = AppFeature.State(
      restore: .storageUnavailable(.unavailable),
      connection: ConnectionFeature.State(
        id: 1,
        server: TestServer.server,
        phase: .connected,
        projects: [],
        isPinned: true
      ),
      savedServer: oldFirst,
      savedServers: [oldFirst, oldSecond],
      isPinnedForUITest: true,
      savedData: .unreadable(.storage(.unavailable))
    )
    state.savedServer = oldFirst
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = shared
    }

    await store.send(.connection(.delegate(.verified(TestServer.server, TestServer.info)))) {
      $0.savedServer = TestServer.server
      $0.savedServers = [TestServer.server, oldFirst, oldSecond]
    }
    #expect(keychain.writes == 0)

    await store.send(.replaceSavedDataTapped) {
      $0.showsReplaceSavedDataConfirmation = true
    }
    keychain.setFailing(false)
    await store.send(.replaceSavedDataConfirmed) {
      $0.showsReplaceSavedDataConfirmation = false
    }
    await store.receive(
      .replaceSavedDataFinished(
        .success(
          .init(
            server: TestServer.server,
            servers: [TestServer.server, oldFirst, oldSecond]
          )
        )
      )
    ) {
      $0.savedData = .read
      $0.restore = .ready
      $0.savedServer = TestServer.server
      $0.savedServers = [TestServer.server, oldFirst, oldSecond]
    }

    #expect(keychain.writes == 3)
    #expect(shared.result(ServerSharedKeys.savedServer) == .success(TestServer.server))
    #expect(
      shared.result(ServerSharedKeys.savedServers)
        == .success([TestServer.server, oldFirst, oldSecond])
    )
  }

  @Test("a temporary read failure reconciles the old list when the retry succeeds")
  func temporaryReadFailureReconciles() async {
    let oldFirst = OpenCodeServer(url: "http://10.0.0.2:4096", password: "old-one")
    let oldSecond = OpenCodeServer(url: "http://10.0.0.3:4096", password: "old-two")
    let seedKeychain = OpenCodeCore.InMemoryStorage()
    let seedStore = SharedStore(defaults: OpenCodeCore.InMemoryStorage(), keychain: seedKeychain)
    #expect(seedStore.write(oldFirst, for: ServerSharedKeys.savedServer) == .success)
    #expect(seedStore.write([oldFirst, oldSecond], for: ServerSharedKeys.savedServers) == .success)

    let keychain = ToggleStorage(failing: true)
    if case .value(let data) = seedKeychain.read(ServerSharedKeys.savedServer.name) {
      _ = keychain.seed(data, for: ServerSharedKeys.savedServer.name)
    }
    if case .value(let data) = seedKeychain.read(ServerSharedKeys.savedServers.name) {
      _ = keychain.seed(data, for: ServerSharedKeys.savedServers.name)
    }
    let shared = storage(keychain: keychain)

    var state = AppFeature.State(
      restore: .storageUnavailable(.unavailable),
      connection: ConnectionFeature.State(
        id: 1,
        server: TestServer.server,
        phase: .connected,
        projects: [],
        isPinned: true
      ),
      isPinnedForUITest: true,
      savedData: .unreadable(.storage(.unavailable))
    )
    state.savedData = .unreadable(.storage(.unavailable))
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = shared
    }

    await store.send(.connection(.delegate(.verified(TestServer.server, TestServer.info)))) {
      $0.savedServer = TestServer.server
      $0.savedServers = [TestServer.server]
    }
    #expect(keychain.writes == 0)

    keychain.setFailing(false)
    await store.send(.restoreRetried) {
      $0.restore = .idle
    }
    await store.receive(
      .restored(.restored(server: oldFirst, servers: [oldFirst, oldSecond], cache: nil, notice: nil))
    ) {
      $0.restore = .ready
      $0.savedData = .read
      $0.savedServer = TestServer.server
      $0.savedServers = [TestServer.server, oldFirst, oldSecond]
    }
    store.exhaustivity = .off
    await settle(store)
    #expect(keychain.writes == 3)
    #expect(
      shared.result(ServerSharedKeys.savedServers)
        == .success([TestServer.server, oldFirst, oldSecond])
    )
  }

  @Test("replacing unreadable data reports a delete failure and keeps the warning")
  func replaceFailureKeepsUnreadableState() async {
    let keychain = ToggleStorage(failing: true)
    let shared = storage(keychain: keychain)
    var state = AppFeature.State(
      restore: .storageUnavailable(.unavailable),
      connection: ConnectionFeature.State(
        id: 1,
        server: TestServer.server,
        phase: .connected,
        projects: [],
        isPinned: true
      ),
      savedServer: TestServer.server,
      savedServers: [TestServer.server],
      isPinnedForUITest: true,
      savedData: .unreadable(.storage(.unavailable))
    )
    state.showsReplaceSavedDataConfirmation = true
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = shared
    }

    await store.send(.replaceSavedDataConfirmed) {
      $0.showsReplaceSavedDataConfirmation = false
    }
    await store.receive(
      .replaceSavedDataFinished(.failure(.storage(.unavailable)))
    ) {
      $0.notice = .couldNotReplaceSavedData(.unavailable)
    }
    #expect(store.state.savedData == .unreadable(.storage(.unavailable)))
    #expect(keychain.writes == 0)
  }

  private func settle(_ store: TestStoreOf<AppFeature>) async {
    for _ in 0..<10 {
      await store.finish()
      await store.skipReceivedActions(strict: false)
    }
  }

  private func quietPath() -> NetworkPathClient {
    NetworkPathClient(
      current: { .online },
      updates: { AsyncStream { $0.finish() } },
      waitUntilAvailable: {}
    )
  }


  private final class CallCount: Sendable {
    private let value = Mutex<Int>(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
  }

  private func countingClient(calls: CallCount) -> OpenCodeClient {
    OpenCodeClient(
      health: { _ in throw OpenCodeClientError(.unsupported) },
      redeemPairing: { _ in throw OpenCodeClientError(.unsupported) },
      projects: { _ in throw OpenCodeClientError(.unsupported) },
      sessionPage: { _, _, _ in
        calls.increment()
        return SessionPage(sessions: [], next: nil)
      },
      getSession: { _, _ in throw OpenCodeClientError(.unsupported) },
      activeSessionIDs: { _ in [] },
      events: { _, _ in
        AsyncThrowingStream { $0.finish(throwing: OpenCodeClientError(.unreachable)) }
      }
    )
  }

  private func homeState() -> HomeFeature.State {
    HomeFeature.State(
      server: TestServer.server,
      projects: TestServer.projects,
      isLive: false,
      hasLoaded: true
    )
  }

  @Test("foreground return while authenticating does not make Home live")
  func homeStaysInactiveWhileAuthenticating() async {
    let calls = CallCount()
    var state = AppFeature.State()
    state.isPinnedForUITest = true
    state.savedData = .read
    state.isInForeground = false
    state.connection = ConnectionFeature.State(
      id: 1,
      server: TestServer.server,
      phase: .connecting,
      isPinned: true
    )
    state.home = homeState()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = self.storage()
      $0.openCodeClient = self.countingClient(calls: calls)
    }
    store.exhaustivity = .off

    await store.send(.scenePhaseChanged(isActive: true))
    await store.receive(.connection(.scenePhaseChanged(isActive: true)))
    await store.receive(.home(.connectionChanged(isConnected: false)))
    #expect(store.state.home?.isLive == false)
    #expect(calls.count == 0)
  }

  @Test("foreground return while offline does not make Home live")
  func homeStaysInactiveWhileOffline() async {
    let calls = CallCount()
    var state = AppFeature.State()
    state.isPinnedForUITest = true
    state.savedData = .read
    state.isInForeground = false
    state.networkPath = .offline
    state.connection = ConnectionFeature.State(
      id: 1,
      server: TestServer.server,
      phase: .connected,
      isPinned: true
    )
    state.home = homeState()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = self.storage()
      $0.openCodeClient = self.countingClient(calls: calls)
    }
    store.exhaustivity = .off

    await store.send(.scenePhaseChanged(isActive: true))
    await store.receive(.connection(.scenePhaseChanged(isActive: true)))
    await store.receive(.home(.connectionChanged(isConnected: false)))
    #expect(store.state.home?.isLive == false)
    #expect(calls.count == 0)
  }

  @Test("path loss stops Home and a stream reconnect resumes one refresh")
  func homeFollowsPathAndReconnect() async {
    let calls = CallCount()
    var state = AppFeature.State()
    state.isPinnedForUITest = true
    state.savedData = .read
    state.connection = ConnectionFeature.State(
      id: 1,
      server: TestServer.server,
      phase: .connected,
      isPinned: true
    )
    state.home = HomeFeature.State(
      server: TestServer.server,
      projects: TestServer.projects,
      isLive: true,
      hasLoaded: true
    )
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = self.storage()
      $0.openCodeClient = self.countingClient(calls: calls)
    }
    store.exhaustivity = .off

    await store.send(.networkPathChanged(.offline))
    await store.receive(.connection(.networkPathChanged(.offline)))
    await store.receive(.home(.connectionChanged(isConnected: false)))
    #expect(store.state.home?.isLive == false)
    #expect(calls.count == 0)

    await store.send(.connection(.delegate(.available(TestServer.server))))
    await store.receive(.home(.connectionResynchronized))
    await store.receive(
      .home(
        .refreshed(
          generation: store.state.home!.generation,
          request: store.state.home!.refreshRequest,
          result: .success(HomeRefresh(sessions: [], next: nil, activeSessionIDs: []))
        )
      )
    )
    #expect(store.state.home?.isLive == true)
    #expect(calls.count == 1)
  }

  @Test("a stream interruption makes Home inactive until REST is available again")
  func homeStopsOnInterruption() async {
    let calls = CallCount()
    var state = AppFeature.State()
    state.isPinnedForUITest = true
    state.savedData = .read
    state.connection = ConnectionFeature.State(
      id: 1,
      server: TestServer.server,
      phase: .connected,
      isPinned: true
    )
    state.home = HomeFeature.State(
      server: TestServer.server,
      projects: TestServer.projects,
      isLive: true,
      hasLoaded: true
    )
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = self.storage()
      $0.openCodeClient = self.countingClient(calls: calls)
    }
    store.exhaustivity = .off

    await store.send(.connection(.delegate(.unavailable(TestServer.server))))
    await store.receive(.home(.connectionChanged(isConnected: false)))
    #expect(store.state.home?.isLive == false)
    #expect(calls.count == 0)
  }

  @Test("a Home server switch replaces the connection")
  func homeServerSwitch() async {
    var state = AppFeature.State()
    state.isPinnedForUITest = true
    state.savedData = .read
    state.connection = ConnectionFeature.State(
      id: 1,
      server: TestServer.server,
      phase: .connected,
      projects: [],
      isPinned: true
    )
    state.home = HomeFeature.State(server: TestServer.server, isPinned: true)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.sharedStore = self.storage()
    }
    store.exhaustivity = .off

    await store.send(.home(.delegate(.switchServer(TestServer.other))))
    #expect(store.state.connection?.server == TestServer.other)
    #expect(store.state.home == nil)
  }

}

final class ToggleStorage: KeyValueStorage, Sendable {
  private let inner = OpenCodeCore.InMemoryStorage()
  private let failing: Mutex<Bool>
  private let writeCounter = Mutex(0)

  init(failing: Bool) {
    self.failing = Mutex(failing)
  }

  var writes: Int { writeCounter.withLock { $0 } }

  func setFailing(_ value: Bool) {
    failing.withLock { $0 = value }
  }

  func seed(_ data: Data, for key: String) -> StorageWrite {
    inner.write(data, for: key)
  }

  func read(_ key: String) -> StorageRead {
    if failing.withLock({ $0 }) { return .failure(.unavailable) }
    return inner.read(key)
  }

  func write(_ data: Data, for key: String) -> StorageWrite {
    _ = writeCounter.withLock { $0 += 1 }
    if failing.withLock({ $0 }) { return .failure(.unavailable) }
    return inner.write(data, for: key)
  }

  func delete(_ key: String) -> StorageWrite {
    if failing.withLock({ $0 }) { return .failure(.unavailable) }
    return inner.delete(key)
  }
}

private extension SharedRead {
  var isMissing: Bool {
    if case .missing = self { return true }
    return false
  }
}
