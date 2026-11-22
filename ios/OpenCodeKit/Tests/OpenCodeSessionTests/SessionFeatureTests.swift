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
    stopShell: @escaping @Sendable (OpenCodeServer, String, String) async throws -> Void = {
      _, _, _ in
    },
    shellOutput: @escaping @Sendable (OpenCodeServer, String, String, Int, Int) async throws ->
      ShellOutputPage = { _, _, _, _, _ in ShellOutputPage(output: "", cursor: 0, size: 0) },
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
