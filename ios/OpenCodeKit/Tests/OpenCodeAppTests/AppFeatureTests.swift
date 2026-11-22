import ComposableArchitecture
import Foundation
import OpenCodeApp
import OpenCodeCore
import OpenCodeServer
import OpenCodeTestSupport
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
    }
    #expect(store.state.savedServer == TestServer.server)
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
    await store.receive(.persisted(saved: .success, list: .success))

    #expect(shared.result(ServerSharedKeys.savedServer) == .success(TestServer.server))
    #expect(shared.result(ServerSharedKeys.savedServers) == .success([TestServer.server]))
  }

  @Test("a keychain write failure keeps the connection and reports the explicit outcome")
  func failedPersistenceIsReported() async {
    let shared = storage(keychain: FailingStorage(failure: .unavailable))
    var state = AppFeature.State()
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

    await store.send(.connection(.delegate(.verified(TestServer.server, TestServer.info)))) {
      $0.savedServer = TestServer.server
      $0.savedServers = [TestServer.server]
    }
    await store.receive(.persisted(saved: .failure(.unavailable), list: .failure(.unavailable))) {
      $0.notice = .couldNotSaveServer(.unavailable)
    }
  }

  @Test("re-connecting keeps a saved server's local name")
  func verifiedConnectionKeepsLocalName() async {
    let shared = storage()
    var saved = TestServer.server
    saved.name = "Desk"
    var state = AppFeature.State(savedServer: saved, savedServers: [saved])
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

    await store.send(.connection(.delegate(.verified(TestServer.server, TestServer.info))))
    await store.receive(.persisted(saved: .success, list: .success))
    #expect(store.state.savedServer?.name == "Desk")
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

    await store.send(.forgetSavedServersTapped) {
      $0.savedServer = nil
      $0.savedServers = []
      $0.restore = .ready
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

  private func quietPath() -> NetworkPathClient {
    NetworkPathClient(
      current: { .online },
      updates: { AsyncStream { $0.finish() } },
      waitUntilAvailable: {}
    )
  }
}

private extension SharedRead {
  var isMissing: Bool {
    if case .missing = self { return true }
    return false
  }
}
