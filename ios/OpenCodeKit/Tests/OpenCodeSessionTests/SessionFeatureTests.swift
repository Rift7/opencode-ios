import ComposableArchitecture
import Foundation
import OpenCodeCore
import OpenCodeServer
import OpenCodeSession
import Synchronization
import Testing

@MainActor
@Suite("Session feature", .serialized)
struct SessionFeatureTests {
  private let server = OpenCodeServer(
    url: "http://127.0.0.1:4110",
    username: "opencode",
    password: "test-token"
  )

  private var root: OpenCodeSession {
    OpenCodeSession(
      id: "root",
      serverTitle: "Root",
      projectID: "p1",
      directory: "/work/opencode",
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      idleMilliseconds: 2_000,
      viewedMilliseconds: 1_000,
      agent: "build"
    )
  }

  private func child(_ id: String, parent: String = "root") -> OpenCodeSession {
    OpenCodeSession(
      id: id,
      serverTitle: id,
      projectID: "p1",
      directory: "/work/opencode",
      updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
      parentID: parent,
      agent: "explore"
    )
  }

  private func state(
    session: OpenCodeSession? = nil,
    requests: SessionRequests = SessionRequests(),
    pendingInputs: [PendingInput] = []
  ) -> SessionFeature.State {
    var state = SessionFeature.State(
      id: 1,
      server: server,
      selection: SessionSelection(
        serverID: server.persistenceID,
        sessionID: "root",
        intent: .browse
      ),
      session: session ?? root
    )
    state.requests = requests
    state.pendingInputs = pendingInputs
    return state
  }

  private func makeStore(
    _ state: SessionFeature.State,
    client: OpenCodeClient,
    clock: ClockClient = .testValue
  ) -> TestStoreOf<SessionFeature> {
    let store = TestStore(initialState: state) {
      SessionFeature()
    } withDependencies: {
      $0.openCodeClient = client
      $0.clock = clock
      $0.networkPath = NetworkPathClient(
        current: { .online },
        updates: { AsyncStream { $0.finish() } },
        waitUntilAvailable: {}
      )
      $0.haptics = .testValue
    }
    store.exhaustivity = .off
    return store
  }

  private func client(
    getSession: @escaping @Sendable (OpenCodeServer, String) async throws -> OpenCodeSession,
    family: @escaping @Sendable (OpenCodeServer, OpenCodeSession) async throws -> SessionFamily = {
      _, root in SessionFamily(root: root, sessions: [root])
    },
    requests: @escaping @Sendable (OpenCodeServer, OpenCodeSession, [String]) async throws ->
      PendingRequests = { _, _, _ in PendingRequests() },
    active: @escaping @Sendable (OpenCodeServer, String) async throws -> Bool = { _, _ in false },
    interrupt: @escaping @Sendable (OpenCodeServer, String) async throws -> Bool = { _, _ in true },
    setDelivery: @escaping @Sendable (OpenCodeServer, String, String, PendingInput.Delivery)
      async throws -> Void = { _, _, _, _ in },
    inputs: @escaping @Sendable (OpenCodeServer, String) async throws -> [PendingInput] = { _, _ in [] },
    shells: @escaping @Sendable (OpenCodeServer, String) async throws -> [ServerShell] = { _, _ in [] },
    jobs: @escaping @Sendable (OpenCodeServer, String) async throws -> [ServerJob] = { _, _ in [] },
    shell: @escaping @Sendable (OpenCodeServer, String, String) async throws -> ServerShell = {
      _, _, id in ServerShell(id: id, command: "cmd")
    },
    shellOutput: @escaping @Sendable (OpenCodeServer, String, String, Int, Int) async throws ->
      ShellOutputPage = { _, _, _, _, _ in ShellOutputPage(output: "", cursor: 0, size: 0) },
    stopShell: @escaping @Sendable (OpenCodeServer, String, String) async throws -> Void = {
      _, _, _ in
    },
    replyPermission: @escaping @Sendable (
      OpenCodeServer, String, String, PermissionDecision, String?
    ) async throws -> Void = { _, _, _, _, _ in },
    replyForm: @escaping @Sendable (
      OpenCodeServer, String, String, [String: FormValue], String?
    ) async throws -> FormReplyOutcome = { _, _, _, _, _ in .settled },
    cancelForm: @escaping @Sendable (
      OpenCodeServer, String, String, String?, String?
    ) async throws -> FormReplyOutcome = { _, _, _, _, _ in .settled }
  ) -> OpenCodeClient {
    OpenCodeClient(
      health: { _ in throw OpenCodeClientError(.unsupported) },
      redeemPairing: { _ in throw OpenCodeClientError(.unsupported) },
      projects: { _ in [] },
      sessionPage: { _, _, _ in SessionPage(sessions: []) },
      getSession: getSession,
      activeSessionIDs: { _ in [] },
      interruptSession: interrupt,
      sessionIsActive: active,
      sessionFamily: family,
      pendingRequests: requests,
      replyPermission: replyPermission,
      replyForm: replyForm,
      cancelForm: cancelForm,
      pendingInputs: inputs,
      setPendingInputDelivery: setDelivery,
      runningShells: shells,
      shell: shell,
      shellOutput: shellOutput,
      stopShell: stopShell,
      runningJobs: jobs,
      events: { _, _ in AsyncThrowingStream { $0.finish() } }
    )
  }

  /// Runs an effect, applies every action it sent, and repeats for any follow-up effects.
  private func settle(_ store: TestStoreOf<SessionFeature>) async {
    for _ in 0..<8 {
      await store.finish()
      await store.skipReceivedActions(strict: false)
    }
  }

  private func waitUntil(
    _ condition: @escaping () async -> Bool,
    timeout: Duration = .seconds(3)
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
  }

  @Test("lifecycle duplicates coalesce into one read and one follow-up")
  func refreshCoalescing() async {
    let gate = Gate()
    let calls = CallCounter()
    let rootSession = root
    let client = client(
      getSession: { _, _ in
        await calls.increment("refresh")
        await gate.wait()
        return rootSession
      }
    )
    let store = makeStore(state(), client: client)

    await store.send(.task)
    #expect(await waitUntil { await calls.count("refresh") == 1 })

    await store.send(.refreshRequested(.resume))
    await store.send(.refreshRequested(.watchdog))
    #expect(await calls.count("refresh") == 1)
    #expect(store.state.refresh?.followup == nil)

    await store.send(.refreshRequested(.invalidation))
    #expect(await calls.count("refresh") == 1)
    #expect(store.state.refresh?.followup == .invalidation)

    await gate.open()
    await settle(store)
    #expect(await calls.count("refresh") == 2)
    #expect(store.state.refresh == nil)
  }

  @Test("an event that raced a snapshot is replayed onto its result")
  func snapshotEventRace() async {
    let gate = Gate()
    let activeCalls = CallCounter()
    let rootSession = root
    let client = client(
      getSession: { _, _ in
        await gate.wait()
        return rootSession
      },
      active: { _, _ in
        await activeCalls.increment("active")
        return await activeCalls.count("active") == 1
      }
    )
    var initial = state()
    initial.run.isRunning = true
    let store = makeStore(initial, client: client)

    await store.send(.task)
    #expect(await waitUntil { store.state.refresh != nil })
    await store.send(.serverEvent(.executionEnded(sessionID: "root")))
    #expect(store.state.run.isRunning)
    #expect(store.state.refresh?.followup == .runState)

    await gate.open()
    await settle(store)
    #expect(!store.state.run.isRunning)
    #expect(await activeCalls.count("active") >= 2)
  }

  @Test("a durable boundary waits the 200 ms coalescing window")
  func settlementWindow() async {
    let clock = ClockClient.recording()
    let rootSession = root
    let client = client(getSession: { _, _ in rootSession })
    let store = makeStore(state(), client: client, clock: clock.client)

    await store.send(.refreshRequested(.settlement(messageID: "msg-1")))
    await settle(store)
    #expect(store.state.refresh == nil)
    #expect(clock.sleeps.contains(.milliseconds(200)))
  }

  @Test("an ambiguous Stop reads the run instead of interrupting twice")
  func interruptAmbiguity() async {
    let interrupts = CallCounter()
    let rootSession = root
    let client = client(
      getSession: { _, _ in rootSession },
      active: { _, _ in false },
      interrupt: { _, _ in
        await interrupts.increment("interrupt")
        throw OpenCodeClientError(.transport(.interrupted))
      }
    )
    var initial = state()
    initial.run.isRunning = true
    let store = makeStore(initial, client: client)

    await store.send(.interruptTapped)
    await settle(store)
    #expect(!store.state.run.isInterrupting)
    #expect(await interrupts.count("interrupt") == 1)
    #expect(!store.state.run.isRunning)
  }

  @Test("a Stop that lost its answer to a resumed run does not interrupt again")
  func interruptResumed() async {
    let interrupts = CallCounter()
    let rootSession = root
    let client = client(
      getSession: { _, _ in rootSession },
      active: { _, _ in true },
      interrupt: { _, _ in
        await interrupts.increment("interrupt")
        throw OpenCodeClientError(.transport(.interrupted))
      },
      inputs: { _, _ in [] }
    )
    var initial = state()
    initial.run.isRunning = true
    initial.pendingInputs = [
      PendingInput(id: "steer-1", text: "keep going", delivery: .steer)
    ]
    let store = makeStore(initial, client: client)

    await store.send(.interruptTapped)
    await settle(store)
    #expect(store.state.run.isRunning)
    #expect(!store.state.run.isInterrupting)
    #expect(await interrupts.count("interrupt") == 1)
  }

  @Test("a stranded steering message is queued then steered, and wakes the run")
  func strandedSteer() async {
    let order = CallCounter()
    let rootSession = root
    let client = client(
      getSession: { _, _ in rootSession },
      active: { _, _ in true },
      setDelivery: { _, _, _, delivery in
        await order.increment(delivery.rawValue)
      }
    )
    var initial = state()
    initial.pendingInputs = [
      PendingInput(id: "queued-1", text: "resume", delivery: .queue)
    ]
    let store = makeStore(initial, client: client)

    await store.send(.strandedSteerTapped(inputID: "queued-1"))
    await settle(store)
    #expect(await order.count("steer") == 1)
    #expect(await order.count("queue") == 0)
    #expect(store.state.run.isRunning)
  }

  @Test("form validation blocks an invalid answer and a duplicate submit")
  func formValidationAndDuplicate() async {
    let replies = Gate()
    let replyCount = CallCounter()
    let form = FormRequest(
      id: "form-1",
      sessionID: "root",
      title: "Deploy",
      fields: [
        FormField(key: "name", type: .string, title: "Name", required: true)
      ]
    )
    let rootSession = root
    let client = client(
      getSession: { _, _ in rootSession },
      replyForm: { _, _, _, _, _ in
        await replyCount.increment("reply")
        await replies.wait()
        return .settled
      }
    )
    let store = makeStore(state(requests: SessionRequests(forms: [form])), client: client)

    await store.send(.formSubmitTapped("form-1"))
    #expect(
      store.state.requests.failures["form-1"]
        == .validation(.required, fieldKey: "name", fieldIndex: 0)
    )
    #expect(await replyCount.count("reply") == 0)

    await store.send(.requestValueChanged(formID: "form-1", key: "name", value: .string("Ada")))
    await store.send(.formSubmitTapped("form-1"))
    #expect(await waitUntil { await replyCount.count("reply") == 1 })
    await store.send(.formSubmitTapped("form-1"))
    #expect(await replyCount.count("reply") == 1)

    await replies.open()
    await settle(store)
    #expect(store.state.requests.form("form-1") == nil)
    #expect(store.state.requests.completedIDs.contains("form-1"))
  }

  @Test("a form answered elsewhere is settled, not actionable again")
  func formConflict() async {
    let form = FormRequest(
      id: "form-1",
      sessionID: "root",
      title: "Deploy",
      fields: [FormField(key: "name", type: .string, title: "Name", defaultValue: .string("Ada"))]
    )
    let rootSession = root
    let client = client(
      getSession: { _, _ in rootSession },
      replyForm: { _, _, _, _, _ in .conflict(.answeredElsewhere) }
    )
    let store = makeStore(state(requests: SessionRequests(forms: [form])), client: client)

    await store.send(.formSubmitTapped("form-1"))
    await settle(store)
    #expect(store.state.requests.form("form-1") == nil)
    #expect(store.state.requests.failures["form-1"] == .conflict(.answeredElsewhere))
    #expect(store.state.requests.completedIDs.contains("form-1"))
  }

  @Test("only a denial carries a reason, and Always requires save patterns")
  func permissionRules() async {
    let replies = CallCounter()
    let request = PermissionRequest(
      id: "perm-1",
      sessionID: "root",
      action: "bash",
      resources: ["rm -rf build"]
    )
    let rootSession = root
    let client = client(
      getSession: { _, _ in rootSession },
      replyPermission: { _, _, _, decision, message in
        await replies.increment("\(decision.rawValue):\(message ?? "")")
      }
    )
    let store = makeStore(
      state(requests: SessionRequests(permissions: [request])),
      client: client
    )

    await store.send(
      .permissionReplyTapped(id: "perm-1", decision: .always, message: nil)
    )
    #expect(await replies.all.isEmpty)

    await store.send(
      .permissionReplyTapped(id: "perm-1", decision: .reject, message: " use make ")
    )
    await settle(store)
    #expect(await replies.all == ["reject:use make"])
  }

  @Test("family pages open and return without losing the root")
  func subagentNavigation() async {
    let rootSession = root
    let childA = child("child-a")
    let childB = child("child-b")
    let family = SessionFamily(
      root: rootSession,
      sessions: [rootSession, childA, childB],
      activeSessionIDs: ["child-a"]
    )
    let client = client(
      getSession: { _, id in
        if id == "child-a" { return childA }
        if id == "child-b" { return childB }
        return rootSession
      },
      family: { _, _ in family }
    )
    let store = makeStore(state(), client: client)

    await store.send(.task)
    await settle(store)
    #expect(store.state.subagents.count == 2)
    #expect(store.state.subagents.map(\.id) == ["child-a", "child-b"])

    await store.send(.openSubagent("child-a"))
    await settle(store)
    #expect(store.state.activeSessionID == "child-a")
    #expect(store.state.pages.count == 1)

    await store.send(.openSubagent("child-b"))
    await settle(store)
    #expect(store.state.activeSessionID == "child-b")
    #expect(store.state.pages.count == 2)

    await store.send(.popPage)
    await settle(store)
    #expect(store.state.activeSessionID == "child-a")
    await store.send(.popPage)
    await settle(store)
    #expect(store.state.isAtRoot)
    #expect(store.state.root?.id == "root")
  }


  @Test("changing pages abandons the read that belonged to the old page")
  func pageChangeAbandonsRead() async {
    let gate = Gate()
    let rootSession = root
    let childSession = child("child-a")
    let family = SessionFamily(
      root: rootSession,
      sessions: [rootSession, childSession],
      activeSessionIDs: []
    )
    var initial = state()
    initial.family = family
    initial.pages = [
      SessionPage(id: 1, sessionID: "child-a", title: "child-a", parentPageID: nil)
    ]
    let client = client(
      getSession: { _, id in
        await gate.wait()
        return id == "child-a" ? childSession : rootSession
      },
      family: { _, _ in family }
    )
    let store = makeStore(initial, client: client)

    await store.send(.task)
    #expect(store.state.refresh != nil)
    await store.send(.popPage)
    #expect(store.state.isAtRoot)
    #expect(store.state.refresh?.id == 2)
    await gate.open()
    await settle(store)
    #expect(store.state.root?.id == "root")
    #expect(store.state.refresh == nil)
  }

  @Test("a replacement connection falsifies an in-flight read")
  func staleSnapshotIgnored() async {
    let gate = Gate()
    let rootSession = root
    let client = client(
      getSession: { _, _ in
        await gate.wait()
        return rootSession
      }
    )
    let store = makeStore(state(), client: client)

    await store.send(.task)
    #expect(store.state.refresh != nil)
    await store.send(.connectionChanged(isConnected: false))
    #expect(store.state.refresh == nil)
    await gate.open()
    await settle(store)
    #expect(store.state.refresh == nil)
  }


  @Test("a missing shell marks its output unavailable; earlier bytes join the retained window")
  func shellEarlierAndMissing() async {
    let rootSession = root
    let shell = ServerShell(id: "shell-1", command: "swift test", sessionID: "root")
    let missing = client(
      getSession: { _, _ in rootSession },
      shellOutput: { _, _, _, _, _ in throw OpenCodeClientError(.status(404)) }
    )
    var initial = state()
    initial.background.shells = [shell]
    let missingStore = makeStore(initial, client: missing)
    await missingStore.send(.shellOutputTapped(shellID: "shell-1"))
    await settle(missingStore)
    #expect(missingStore.state.background.output?.isUnavailable == true)

    let paged = client(
      getSession: { _, _ in rootSession },
      shellOutput: { _, _, _, cursor, limit in
        if cursor == 0 {
          return ShellOutputPage(output: "a", cursor: 1, size: 2)
        }
        return ShellOutputPage(output: "", cursor: cursor, size: 2)
      }
    )
    var earlier = state()
    earlier.background.output = ShellOutputState(
      shellID: "shell-1",
      title: "swift test",
      output: "b",
      startCursor: 1,
      endCursor: 1,
      size: 2
    )
    let earlierStore = makeStore(earlier, client: paged)
    await earlierStore.send(.shellEarlierTapped)
    await settle(earlierStore)
    #expect(earlierStore.state.background.output?.output == "ab")
    #expect(earlierStore.state.background.output?.startCursor == 0)
  }


  @Test("a selection with no cached session loads, fails, retries and survives a reconnect")
  func uncachedInitialLoad() async {
    let mode = MutableResult()
    let rootSession = root
    let client = client(getSession: { _, _ in
      switch await mode.current {
      case .success: return rootSession
      case .failure: throw OpenCodeClientError(.status(500))
      case .gated(let gate):
        await gate.wait()
        return rootSession
      }
    })
    var cold = SessionFeature.State(
      id: 1,
      server: server,
      selection: SessionSelection(
        serverID: server.persistenceID, sessionID: "root", intent: .browse
      )
    )
    cold.isLive = true
    let successStore = makeStore(cold, client: client)
    await successStore.send(.task)
    await settle(successStore)
    #expect(successStore.state.root?.id == "root")
    #expect(successStore.state.loadProblem == nil)

    await mode.set(.failure)
    let failureStore = makeStore(cold, client: client)
    await failureStore.send(.task)
    await settle(failureStore)
    #expect(failureStore.state.root == nil)
    #expect(failureStore.state.loadProblem == .serverStatus(500))

    await mode.set(.success)
    await failureStore.send(.retryTapped)
    await settle(failureStore)
    #expect(failureStore.state.root?.id == "root")

    let gate = Gate()
    await mode.set(.gated(gate))
    let interrupted = makeStore(cold, client: client)
    await interrupted.send(.task)
    #expect(interrupted.state.refresh != nil)
    await interrupted.send(.connectionChanged(isConnected: false))
    await gate.open()
    await settle(interrupted)
    #expect(interrupted.state.root == nil)
    #expect(interrupted.state.refresh == nil)
    await mode.set(.success)
    await interrupted.send(.connectionChanged(isConnected: true))
    await settle(interrupted)
    #expect(interrupted.state.root?.id == "root")
  }

  @Test("subagent navigation keeps the root family, clears an inactive child and keeps answers")
  func familyIdentityAcrossPages() async {
    let rootSession = root
    let childA = child("child-a")
    let childB = child("child-b")
    let family = SessionFamily(
      root: rootSession,
      sessions: [rootSession, childA, childB],
      activeSessionIDs: []
    )
    let roots = RootRecorder()
    let form = FormRequest(
      id: "form-1",
      sessionID: "root",
      title: "Deploy",
      fields: [FormField(key: "name", type: .string, title: "Name")]
    )
    let client = client(
      getSession: { _, id in
        switch id {
        case "child-a": return childA
        case "child-b": return childB
        default: return rootSession
        }
      },
      family: { _, supplied in
        await roots.record(supplied.id)
        // Mimic the live walk: a child root returns only that child's subtree.
        if supplied.id == rootSession.id {
          return SessionFamily(
            root: rootSession,
            sessions: [rootSession, childA, childB],
            activeSessionIDs: []
          )
        }
        return SessionFamily(root: supplied, sessions: [supplied], activeSessionIDs: [])
      },
      requests: { _, _, _ in PendingRequests(forms: [form]) },
      active: { _, _ in false }
    )
    var initial = state(requests: SessionRequests(forms: [form]))
    initial.family = family
    initial.run.isRunning = true
    initial.requests.answers["form-1"] = ["name": .string("unsent")]
    let store = makeStore(initial, client: client)

    await store.send(.task)
    await settle(store)
    await store.send(.openSubagent("child-a"))
    await settle(store)
    #expect(store.state.family?.root.id == "root")
    #expect(store.state.activeSessionID == "child-a")
    #expect(!store.state.run.isRunning)
    #expect(store.state.requests.answers["form-1"]?["name"] == .string("unsent"))
    #expect(await roots.all.allSatisfy { $0 == "root" })

    await store.send(.openSubagent("child-b"))
    await settle(store)
    #expect(store.state.family?.root.id == "root")
    #expect(store.state.pages.count == 2)
    #expect(store.state.requests.answers["form-1"]?["name"] == .string("unsent"))

    await store.send(.popPage)
    await settle(store)
    #expect(store.state.activeSessionID == "child-a")
    await store.send(.popPage)
    await settle(store)
    #expect(store.state.isAtRoot)
    #expect(store.state.family?.root.id == "root")
    #expect(store.state.requests.answers["form-1"]?["name"] == .string("unsent"))
  }

  @Test("shell polling starts when visibility and the initial tail both arrive")
  func shellPollTiming() async {
    let shellSession = root
    let shells = CallCounter()
    let outputs = CallCounter()
    let shell = ServerShell(id: "shell-1", command: "swift test", sessionID: "root")
    let client = client(
      getSession: { _, _ in shellSession },
      shell: { _, _, _ in
        await shells.increment("shell")
        return shell
      },
      shellOutput: { _, _, _, cursor, _ in
        await outputs.increment("output")
        return ShellOutputPage(output: "x", cursor: 1, size: 1)
      }
    )
    var early = state()
    early.background.output = ShellOutputState(
      shellID: "shell-1", title: "swift test", isVisible: false
    )
    let clock = ClockClient.suspended
    let earlyStore = makeStore(early, client: client, clock: clock)
    await earlyStore.send(.shellOutputAppeared)
    await earlyStore.send(
      .shellOutputPrepared(
        shellID: "shell-1",
        start: 0,
        result: .success(ShellOutputPage(output: "x", cursor: 1, size: 1))
      )
    )
    #expect(await waitUntil { await shells.count("shell") == 1 })
    await earlyStore.send(.shellOutputDisappeared)

    var late = state()
    late.background.output = ShellOutputState(
      shellID: "shell-1", title: "swift test", isVisible: false
    )
    let lateStore = makeStore(late, client: client, clock: clock)
    await lateStore.send(
      .shellOutputPrepared(
        shellID: "shell-1",
        start: 0,
        result: .success(ShellOutputPage(output: "x", cursor: 1, size: 1))
      )
    )
    #expect(await shells.count("shell") == 1)
    await lateStore.send(.shellOutputAppeared)
    #expect(await waitUntil { await shells.count("shell") == 2 })
    await lateStore.send(.shellOutputDisappeared)

    var dismissed = state()
    dismissed.background.output = ShellOutputState(
      shellID: "shell-1", title: "swift test", isVisible: false
    )
    let dismissedStore = makeStore(dismissed, client: client, clock: clock)
    await dismissedStore.send(.shellOutputAppeared)
    await dismissedStore.send(.backgroundDismissed)
    await dismissedStore.send(
      .shellOutputPrepared(
        shellID: "shell-1",
        start: 0,
        result: .success(ShellOutputPage(output: "x", cursor: 1, size: 1))
      )
    )
    #expect(dismissedStore.state.background.output == nil)

    var reconnected = state()
    reconnected.background.output = ShellOutputState(
      shellID: "shell-1",
      title: "swift test",
      output: "x",
      startCursor: 0,
      endCursor: 1,
      size: 1,
      isVisible: true
    )
    let reconnectStore = makeStore(reconnected, client: client, clock: clock)
    await reconnectStore.send(.connectionChanged(isConnected: false))
    await reconnectStore.send(.connectionChanged(isConnected: true))
    #expect(await waitUntil { await shells.count("shell") >= 3 })
    await reconnectStore.send(.shellOutputDisappeared)
  }

  @Test("trimmed output advances its range by the discarded bytes and stays contiguous")
  func shellRangeContiguity() async {
    let shellSession = root
    let client = client(
      getSession: { _, _ in shellSession },
      shellOutput: { _, _, _, cursor, _ in
        let text = cursor == 3 ? "🙂" : ""
        return ShellOutputPage(output: text, cursor: 7, size: 7)
      }
    )
    var state = self.state()
    state.background.output = ShellOutputState(
      shellID: "shell-1",
      title: "swift test",
      output: "aé",
      startCursor: 0,
      endCursor: 3,
      size: 7,
      retainLimit: 4
    )
    let store = makeStore(state, client: client)
    await store.send(
      .shellOutputLoaded(
        shellID: "shell-1",
        result: .success(ShellOutputPage(output: "🙂", cursor: 7, size: 7))
      )
    )
    let output = store.state.background.output!
    #expect(output.output == "🙂")
    #expect(output.startCursor == 3)
    #expect(output.startCursor + output.output.utf8.count == output.endCursor)
  }

  @Test("Load Earlier joins the retained range and never exceeds the 4 MiB window")
  func shellEarlierBounded() async {
    let shellSession = root
    let maximum = ShellOutputState.maximumRetainedBytes
    let current = String(repeating: "a", count: maximum - 2)
    let start = 100
    let end = start + current.utf8.count
    let client = client(
      getSession: { _, _ in shellSession },
      shellOutput: { _, _, _, _, _ in
        ShellOutputPage(
          output: String(repeating: "b", count: 10),
          cursor: start,
          size: end
        )
      }
    )
    var state = self.state()
    state.background.output = ShellOutputState(
      shellID: "shell-1",
      title: "swift test",
      output: current,
      startCursor: start,
      endCursor: end,
      size: end,
      retainLimit: maximum
    )
    let store = makeStore(state, client: client)
    await store.send(.shellEarlierTapped)
    await settle(store)
    let output = store.state.background.output!
    #expect(output.output.utf8.count <= maximum)
    #expect(output.startCursor + output.output.utf8.count == output.endCursor)
    #expect(output.output.hasPrefix("bb"))
  }


  @Test("continued output trims the front, then Load Earlier joins the retained range")
  func shellTrimThenEarlier() async {
    let shellSession = root
    let client = client(
      getSession: { _, _ in shellSession },
      shellOutput: { _, _, _, cursor, _ in
        if cursor == 0 {
          return ShellOutputPage(output: "abcdef", cursor: 6, size: 10)
        }
        return ShellOutputPage(output: "", cursor: cursor, size: 10)
      }
    )
    var state = self.state()
    state.background.output = ShellOutputState(
      shellID: "shell-1",
      title: "swift test",
      output: "abcdef",
      startCursor: 0,
      endCursor: 6,
      size: 10,
      retainLimit: 4
    )
    let store = makeStore(state, client: client)
    await store.send(
      .shellOutputLoaded(
        shellID: "shell-1",
        result: .success(ShellOutputPage(output: "ghij", cursor: 10, size: 10))
      )
    )
    #expect(store.state.background.output?.output == "ghij")
    #expect(store.state.background.output?.startCursor == 6)
    #expect(store.state.background.output?.endCursor == 10)

    await store.send(.shellEarlierTapped)
    await settle(store)
    let output = store.state.background.output!
    #expect(output.output == "abcdefghij")
    #expect(output.startCursor == 0)
    #expect(output.startCursor + output.output.utf8.count == output.endCursor)
  }

  @Test("Stop drains every remaining page, and a failed drain does not delete")
  func shellDrainAndFailure() async {
    let shellSession = root
    let stopCalls = CallCounter()
    let draining = client(
      getSession: { _, _ in shellSession },
      shellOutput: { _, _, _, cursor, _ in
        switch cursor {
        case 0: return ShellOutputPage(output: "aaaa", cursor: 4, size: 10)
        case 4: return ShellOutputPage(output: "bbbbbb", cursor: 10, size: 10)
        default: return ShellOutputPage(output: "", cursor: 10, size: 10)
        }
      },
      stopShell: { _, _, _ in
        await stopCalls.increment("stop")
      }
    )
    var initial = state()
    initial.background.output = ShellOutputState(
      shellID: "shell-1",
      title: "swift test",
      endCursor: 0,
      size: 10,
      isStopping: true,
      isVisible: true
    )
    let store = makeStore(initial, client: draining)
    await store.send(.shellStopConfirmed)
    await settle(store)
    #expect(await stopCalls.count("stop") == 1)
    #expect(store.state.background.output?.output == "aaaabbbbbb")
    #expect(store.state.background.output?.endCursor == 10)
    #expect(store.state.background.shells.isEmpty)

    let failing = self.client(
      getSession: { _, _ in shellSession },
      shellOutput: { _, _, _, cursor, _ in
        if cursor == 0 { return ShellOutputPage(output: "aaaa", cursor: 4, size: 10) }
        throw OpenCodeClientError(.status(500))
      },
      stopShell: { _, _, _ in
        await stopCalls.increment("stop")
      }
    )
    var second = state()
    second.background.shells = [
      ServerShell(id: "shell-1", command: "swift test", sessionID: "root")
    ]
    second.background.output = ShellOutputState(
      shellID: "shell-1",
      title: "swift test",
      endCursor: 0,
      size: 10,
      isStopping: true,
      isVisible: true
    )
    let failedStore = makeStore(second, client: failing)
    await failedStore.send(.shellStopConfirmed)
    await settle(failedStore)
    #expect(await stopCalls.count("stop") == 1)
    #expect(failedStore.state.background.output?.requiresDiscardConfirmation == true)
    #expect(failedStore.state.background.output?.endCursor == 4)
    #expect(failedStore.state.background.shells.count == 1)

    await failedStore.send(.shellDiscardUnreadConfirmed)
    await settle(failedStore)
    #expect(await stopCalls.count("stop") == 2)
    #expect(failedStore.state.background.shells.isEmpty)
  }


  @Test("a poll page cannot advance output while Stop is draining")
  func shellPollCannotAdvanceWhileStopping() async {
    let rootSession = root
    var initial = state()
    initial.background.output = ShellOutputState(
      shellID: "shell-1",
      title: "swift test",
      endCursor: 0,
      size: 10,
      isStopping: true
    )
    let store = makeStore(initial, client: client(getSession: { _, _ in rootSession }))
    await store.send(
      .shellOutputLoaded(
        shellID: "shell-1",
        result: .success(ShellOutputPage(output: "aaaa", cursor: 4, size: 10))
      )
    )
    #expect(store.state.background.output?.endCursor == 0)
  }

  @Test("a cancelled drain does not delete the shell")
  func shellDrainCancellation() async {
    let gate = Gate()
    let stopCalls = CallCounter()
    let shellSession = root
    let client = client(
      getSession: { _, _ in shellSession },
      shellOutput: { _, _, _, _, _ in
        await gate.wait()
        return ShellOutputPage(output: "aaaa", cursor: 4, size: 10)
      },
      stopShell: { _, _, _ in
        await stopCalls.increment("stop")
      }
    )
    var initial = state()
    initial.background.shells = [
      ServerShell(id: "shell-1", command: "swift test", sessionID: "root")
    ]
    initial.background.output = ShellOutputState(
      shellID: "shell-1",
      title: "swift test",
      endCursor: 0,
      size: 10,
      isStopping: true,
      isVisible: true
    )
    let store = makeStore(initial, client: client)
    await store.send(.shellStopConfirmed)
    #expect(await waitUntil { await gate.isWaiting })
    await store.send(.connectionChanged(isConnected: false))
    await gate.open()
    await settle(store)
    #expect(await stopCalls.count("stop") == 0)
    #expect(store.state.background.shells.count == 1)
  }

  @Test("a background shell tails output, loads earlier bytes and stops")
  func shellOutput() async {
    let shell = ServerShell(id: "shell-1", command: "swift test", sessionID: "root")
    let rootSession = root
    let client = client(
      getSession: { _, _ in rootSession },
      shells: { _, _ in [shell] },
      shell: { _, _, _ in shell },
      shellOutput: { _, _, _, cursor, limit in
        let text = "hello world\n"
        let size = text.utf8.count
        let start = cursor == Int.max ? 0 : min(cursor, size)
        let end = min(start + limit, size)
        let bytes = Array(text.utf8)[start..<end]
        return ShellOutputPage(
          output: String(decoding: bytes, as: UTF8.self),
          cursor: end,
          size: size
        )
      }
    )
    let store = makeStore(state(), client: client)

    await store.send(.task)
    await settle(store)
    #expect(store.state.background.shells.count == 1)
    await store.send(.shellOutputTapped(shellID: "shell-1"))
    await settle(store)
    #expect(store.state.background.output?.output == "hello world\n")

    await store.send(.shellOutputExited("shell-1"))
    #expect(store.state.background.output?.isRunning == false)

    await store.send(.shellStopTapped)
    await store.send(.shellStopConfirmed)
    await settle(store)
    #expect(store.state.background.shells.isEmpty)
    #expect(store.state.background.output?.isUnavailable == true)
  }
}

// MARK: - Test doubles

private actor Gate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  var isWaiting: Bool { !waiters.isEmpty }

  func open() {
    isOpen = true
    let pending = waiters
    waiters = []
    for waiter in pending { waiter.resume() }
  }
}

private actor CallCounter {
  private(set) var all: [String] = []

  func increment(_ name: String) {
    all.append(name)
  }

  func count(_ name: String) -> Int {
    all.filter { $0 == name }.count
  }
}


private actor MutableResult {
  enum Mode: Sendable {
    case success
    case failure
    case gated(Gate)
  }

  private(set) var current: Mode = .success

  func set(_ mode: Mode) {
    current = mode
  }
}

private actor RootRecorder {
  private(set) var all: [String] = []

  func record(_ id: String) {
    all.append(id)
  }
}
