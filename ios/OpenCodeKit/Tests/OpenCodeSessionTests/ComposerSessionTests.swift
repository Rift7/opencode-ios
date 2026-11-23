import ComposableArchitecture
import Foundation
import OpenCodeComposer
import OpenCodeCore
import OpenCodeServer
import OpenCodeSession
import Synchronization
import Testing

@MainActor
@Suite("Composer in the session", .serialized)
struct ComposerSessionTests {
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
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  private func state(
    newSession: Bool = false,
    draft: String = "",
    requests: SessionRequests = SessionRequests(),
    pendingInputs: [PendingInput] = [],
    familySessions: [OpenCodeSession] = []
  ) -> SessionFeature.State {
    let selection: SessionSelection
    if newSession {
      selection = SessionSelection(
        serverID: server.persistenceID,
        sessionID: "new-session-id",
        intent: .newSession(directory: "/work/opencode")
      )
    } else {
      selection = SessionSelection(
        serverID: server.persistenceID,
        sessionID: "root",
        intent: .browse
      )
    }
    var state = SessionFeature.State(
      id: 1,
      server: server,
      selection: selection,
      session: newSession ? nil : root
    )
    state.requests = requests
    state.pendingInputs = pendingInputs
    if !familySessions.isEmpty {
      state.family = SessionFamily(
        root: familySessions[0],
        sessions: familySessions
      )
    }
    state.composer.draft = draft
    state.composer.revision = draft.isEmpty ? 0 : 1
    return state
  }

  private struct Calls: Sendable {
    let created = Counter()
    let prompts = PromptRecorder()
    let deliveries = DeliveryRecorder()
    let cancellations = Counter()
    let replies = ReplyRecorder()
  }

  private final class Counter: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
  }

  private final class PromptRecorder: Sendable {
    private let values = Mutex<[(String, PromptBody)]>([])
    func append(_ sessionID: String, _ body: PromptBody) {
      values.withLock { $0.append((sessionID, body)) }
    }
    var all: [(String, PromptBody)] { values.withLock { $0 } }
  }

  private final class DeliveryRecorder: Sendable {
    private let values = Mutex<[(String, PendingInput.Delivery)]>([])
    func append(_ id: String, _ delivery: PendingInput.Delivery) {
      values.withLock { $0.append((id, delivery)) }
    }
    var all: [(String, PendingInput.Delivery)] { values.withLock { $0 } }
  }

  private final class ReplyRecorder: Sendable {
    private let values = Mutex<[(String, PermissionDecision, String?)]>([])
    func append(_ id: String, _ decision: PermissionDecision, _ message: String?) {
      values.withLock { $0.append((id, decision, message)) }
    }
    var all: [(String, PermissionDecision, String?)] { values.withLock { $0 } }
  }

  private final class FormAnswerRecorder: Sendable {
    private let values = Mutex<[[String: FormValue]]>([])
    func append(_ answer: [String: FormValue]) { values.withLock { $0.append(answer) } }
    var all: [[String: FormValue]] { values.withLock { $0 } }
  }

  private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
      if open { return }
      await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
      open = true
      for waiter in waiters { waiter.resume() }
      waiters.removeAll()
    }
  }

  private func makeStore(
    _ state: SessionFeature.State,
    client: OpenCodeClient,
    uuid: UuidClient,
    draftClient: ComposerDraftClient = ComposerDraftClient()
  ) -> TestStoreOf<SessionFeature> {
    let store = TestStore(initialState: state) {
      SessionFeature()
    } withDependencies: {
      $0.openCodeClient = client
      $0.clock = .testValue
      $0.networkPath = NetworkPathClient(
        current: { .online },
        updates: { AsyncStream { $0.finish() } },
        waitUntilAvailable: {}
      )
      $0.haptics = .testValue
      $0.uuidClient = uuid
      $0.composerDrafts = draftClient
    }
    store.exhaustivity = .off
    return store
  }

  private func client(
    calls: Calls = Calls(),
    getSession: @escaping @Sendable (OpenCodeServer, String) async throws -> OpenCodeSession,
    family: @escaping @Sendable (OpenCodeServer, OpenCodeSession) async throws -> SessionFamily = {
      _, root in SessionFamily(root: root, sessions: [root])
    },
    create: @escaping @Sendable (OpenCodeServer, String, String) async throws -> OpenCodeSession = {
      _, _, id in
      OpenCodeSession(
        id: id,
        serverTitle: "New session",
        projectID: "p1",
        directory: "/work/opencode",
        updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
      )
    },
    send: @escaping @Sendable (OpenCodeServer, String, PromptBody) async throws -> Void = { _, _, _ in },
    wait: @escaping @Sendable (OpenCodeServer, String) async throws -> Void = { _, _ in },
    message: @escaping @Sendable (OpenCodeServer, String, String) async throws -> [TranscriptItem] = {
      _, _, _ in []
    },
    inputs: @escaping @Sendable (OpenCodeServer, String) async throws -> [PendingInput] = { _, _ in [] },
    setDelivery: @escaping @Sendable (OpenCodeServer, String, String, PendingInput.Delivery)
      async throws -> Void = { _, _, _, _ in },
    cancelInput: @escaping @Sendable (OpenCodeServer, String, String) async throws -> Void = {
      _, _, _ in
    },
    replyPermission: @escaping @Sendable (
      OpenCodeServer, String, String, PermissionDecision, String?
    ) async throws -> Void = { _, _, _, _, _ in },
    replyForm: @escaping @Sendable (
      OpenCodeServer, String, String, [String: FormValue], String?
    ) async throws -> FormReplyOutcome = { _, _, _, _, _ in .settled },
    transcript: @escaping @Sendable (OpenCodeServer, String, Int) async throws -> TranscriptPage = {
      _, _, _ in TranscriptPage(items: [])
    }
  ) -> OpenCodeClient {
    OpenCodeClient(
      health: { _ in throw OpenCodeClientError(.unsupported) },
      redeemPairing: { _ in throw OpenCodeClientError(.unsupported) },
      projects: { _ in [] },
      sessionPage: { _, _, _ in SessionPage(sessions: []) },
      getSession: getSession,
      activeSessionIDs: { _ in [] },
      interruptSession: { _, _ in true },
      sessionIsActive: { _, _ in false },
      sessionFamily: family,
      pendingRequests: { _, _, _ in PendingRequests() },
      replyPermission: { server, sessionID, id, decision, message in
        calls.replies.append(id, decision, message)
        try await replyPermission(server, sessionID, id, decision, message)
      },
      replyForm: { server, sessionID, id, answer, directory in
        try await replyForm(server, sessionID, id, answer, directory)
      },
      cancelForm: { _, _, _, _, _ in .settled },
      pendingInputs: inputs,
      setPendingInputDelivery: { server, sessionID, id, delivery in
        calls.deliveries.append(id, delivery)
        try await setDelivery(server, sessionID, id, delivery)
      },
      message: message,
      sendPrompt: { server, sessionID, body in
        calls.prompts.append(sessionID, body)
        try await send(server, sessionID, body)
      },
      createSession: { server, directory, id in
        calls.created.increment()
        return try await create(server, directory, id)
      },
      cancelPendingInput: { server, sessionID, id in
        calls.cancellations.increment()
        try await cancelInput(server, sessionID, id)
      },
      waitForIdle: wait,
      events: { _, _ in AsyncThrowingStream { $0.finish() } }
    )
  }

  private func settle(_ store: TestStoreOf<SessionFeature>) async {
    for _ in 0..<12 {
      await store.finish()
      await store.skipReceivedActions(strict: false)
    }
  }

  private func waitUntilPumping(
    _ store: TestStoreOf<SessionFeature>,
    timeout: Duration = .seconds(3),
    _ condition: @escaping () async -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      await store.skipReceivedActions(strict: false)
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    await store.skipReceivedActions(strict: false)
    return await condition()
  }

  private func waitUntil(
    _ condition: @escaping () async -> Bool,
    timeout: Duration = .seconds(3)
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
  }


  @Test("composer typing reaches the child and persists")
  func typingReachesComposer() async {
    let backend = OpenCodeCore.InMemoryStorage()
    let store = TestStore(initialState: state(draft: "")) {
      SessionFeature()
    } withDependencies: {
      $0.openCodeClient = client(getSession: { _, _ in makeRoot() })
      $0.clock = .testValue
      $0.networkPath = NetworkPathClient(current: { .online }, updates: { AsyncStream { $0.finish() } }, waitUntilAvailable: {})
      $0.haptics = .testValue
      $0.composerDrafts = .live(store: ComposerDraftStore(storage: backend, storageKey: "drafts"))
    }
    store.exhaustivity = .off
    await store.send(.composer(.textChanged("typed")))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.composer.draft == "typed")
  }

  @Test("a first send creates one session, posts under a client id and shows an optimistic row")
  func firstSendCreatesSession() async {
    let calls = Calls()
    let waitGate = Gate()
    let fixedID = "11111111-1111-4111-8111-111111111111"
    let client = client(
      calls: calls,
      getSession: { _, _ in makeRoot() },
      wait: { _, _ in await waitGate.wait() }
    )
    let store = makeStore(
      state(newSession: true, draft: "First message"),
      client: client,
      uuid: UuidClient { UUID(uuidString: fixedID)! }
    )

    await store.send(.composer(.sendTapped))
    #expect(await waitUntilPumping(store) { store.state.root != nil })
    #expect(store.state.root?.id == "new-session-id")
    #expect(store.state.composer.target == .session(id: "new-session-id"))
    #expect(store.state.transcripts["new-session-id"]?.items.contains { $0.id == fixedID } == true)
    #expect(calls.created.count == 1)
    #expect(calls.prompts.all.count == 1)
    #expect(calls.prompts.all.first?.1.id == fixedID)
    #expect(calls.prompts.all.first?.1.text == "First message")

    await store.send(.composer(.sendTapped))
    #expect(calls.created.count == 1)
    #expect(calls.prompts.all.count == 1)
    await waitGate.release()
    await settle(store)
  }

  @Test("a created session survives a definite send failure and the text is recoverable")
  func createThenSendFailure() async {
    let calls = Calls()
    let fixedID = "22222222-2222-4222-8222-222222222222"
    let client = client(
      calls: calls,
      getSession: { _, _ in makeRoot() },
      send: { _, _, _ in throw OpenCodeClientError(.status(400)) }
    )
    let store = makeStore(
      state(newSession: true, draft: "Keep this"),
      client: client,
      uuid: UuidClient { UUID(uuidString: fixedID)! }
    )
    await store.send(.composer(.sendTapped))
    await settle(store)
    #expect(store.state.root?.id == "new-session-id")
    #expect(store.state.composer.target == .session(id: "new-session-id"))
    #expect(store.state.composer.draft == "Keep this")
    #expect(store.state.composer.problem == .couldNotSend)
  }

  @Test("an ambiguous send is accepted when the read-back finds it")
  func ambiguousFoundIsAccepted() async {
    let calls = Calls()
    let fixedID = "33333333-3333-4333-8333-333333333333"
    let client = client(
      calls: calls,
      getSession: { _, _ in makeRoot() },
      send: { _, _, _ in throw OpenCodeClientError(.transport(.timedOut)) },
      message: { _, _, id in [.userText(id: id, text: "Hi", source: nil, quotes: [])] }
    )
    let store = makeStore(
      state(draft: "Hi"),
      client: client,
      uuid: UuidClient { UUID(uuidString: fixedID)! }
    )
    await store.send(.composer(.sendTapped))
    await settle(store)
    #expect(calls.prompts.all.count == 1)
    #expect(!store.state.composer.isSending)
    #expect(store.state.composer.problem == nil)
    #expect(store.state.composer.draft.isEmpty)
  }

  @Test("an ambiguous send whose read-back fails stays unverified and is not duplicated")
  func ambiguousUnreadableIsUnverified() async {
    let calls = Calls()
    let fixedID = "44444444-4444-4444-8444-444444444444"
    let client = client(
      calls: calls,
      getSession: { _, _ in makeRoot() },
      send: { _, _, _ in throw OpenCodeClientError(.transport(.interrupted)) },
      message: { _, _, _ in throw OpenCodeClientError(.status(500)) },
      inputs: { _, _ in throw OpenCodeClientError(.status(500)) }
    )
    let store = makeStore(
      state(draft: "Maybe"),
      client: client,
      uuid: UuidClient { UUID(uuidString: fixedID)! }
    )
    await store.send(.composer(.sendTapped))
    await settle(store)
    #expect(calls.prompts.all.count == 1)
    #expect(!store.state.composer.isSending)
    #expect(store.state.composer.problem == .couldNotVerifySend)
    #expect(store.state.composer.draft.isEmpty)
    #expect(store.state.composer.failedSends.count == 1)
    #expect(store.state.composer.failedSends.first?.failure == .ambiguous)
    #expect(store.state.composer.failedSends.first?.messageID == fixedID)
    #expect(store.state.composer.failedSends.first?.text == "Maybe")
  }

  @Test("a retry after a confirmed absence mints a new message id")
  func retryUsesNewMessageID() async {
    let calls = Calls()
    let newID = "55555555-5555-4555-8555-555555555555"
    let client = client(
      calls: calls,
      getSession: { _, _ in makeRoot() },
      message: { _, _, _ in [] },
      inputs: { _, _ in [] }
    )
    var initial = state(draft: "")
    initial.composer.failedSends = [
      FailedComposerSend(
        messageID: "old-id",
        text: "Retry me",
        quotes: [],
        delivery: .steer,
        target: .session(id: "root"),
        reason: .couldNotSend,
        failure: .definite
      )
    ]
    let store = makeStore(
      initial,
      client: client,
      uuid: UuidClient { UUID(uuidString: newID)! }
    )
    await store.send(.composer(.retryFailed(messageID: "old-id")))
    await settle(store)
    #expect(calls.prompts.all.map(\.1.id) == [newID])
    #expect(calls.prompts.all.first?.1.text == "Retry me")
    #expect(store.state.composer.failedSends.isEmpty)
  }

  @Test("Send Now changes a queued inbox input to steering")
  func sendNowChangesDelivery() async {
    let calls = Calls()
    var initial = state(
      pendingInputs: [PendingInput(id: "queued", text: "Later", delivery: .queue)]
    )
    initial.run.isRunning = true
    let client = client(calls: calls, getSession: { _, _ in makeRoot() })
    let store = makeStore(initial, client: client, uuid: .incrementing())
    await store.send(.pendingInputSendNowTapped("queued"))
    await settle(store)
    #expect(calls.deliveries.all.contains { $0.0 == "queued" && $0.1 == .steer })
  }

  @Test("Move to Queue changes a steering inbox input")
  func moveToQueueChangesDelivery() async {
    let calls = Calls()
    var initial = state(
      pendingInputs: [PendingInput(id: "steer", text: "Now", delivery: .steer)]
    )
    initial.run.isRunning = true
    let client = client(calls: calls, getSession: { _, _ in makeRoot() })
    let store = makeStore(initial, client: client, uuid: .incrementing())
    await store.send(.pendingInputQueueTapped("steer"))
    await settle(store)
    #expect(calls.deliveries.all.contains { $0.0 == "steer" && $0.1 == .queue })
  }

  @Test("Cancel withdraws the inbox input through the audited DELETE")
  func cancelInput() async {
    let calls = Calls()
    var initial = state(
      pendingInputs: [PendingInput(id: "queued", text: "Later", delivery: .queue)]
    )
    initial.run.isRunning = true
    let client = client(calls: calls, getSession: { _, _ in makeRoot() })
    let store = makeStore(initial, client: client, uuid: .incrementing())
    await store.send(.pendingInputCancelTapped("queued"))
    await settle(store)
    #expect(calls.cancellations.count == 1)
    #expect(!store.state.pendingInputs.contains { $0.id == "queued" })
  }


  @Test("a late result from another operation cannot touch the current composer")
  func lateSendResultIgnored() async {
    let calls = Calls()
    let gate = Gate()
    let client = client(
      calls: calls,
      getSession: { _, _ in makeRoot() },
      send: { _, _, _ in await gate.wait() }
    )
    let store = makeStore(state(draft: "Current"), client: client, uuid: .incrementing())
    await store.send(.composer(.sendTapped))
    await store.send(
      .composerSendResult(
        operationID: 9_999,
        messageID: "late",
        result: .accepted(sessionID: "root", created: nil)
      )
    )
    #expect(store.state.composer.isSending)
    #expect(store.state.transcripts["root"]?.items.contains { $0.id == "late" } != true)
    await gate.release()
    await settle(store)
  }

  @Test("a docked question pages and submits without sending chat")
  func requestDockQuestion() async {
    let calls = Calls()
    let form = FormRequest(
      id: "form",
      sessionID: "root",
      title: "Question",
      fields: [
        FormField(key: "first", type: .string, title: "First?"),
        FormField(key: "second", type: .string, title: "Second?"),
      ],
      metadata: ["kind": .string("question")]
    )
    var requests = SessionRequests()
    requests.forms = [form]
    requests.answers = [form.id: form.defaultAnswers]
    requests.selectedID = form.id
    var initial = state(draft: "Chat draft", requests: requests)
    let client = client(calls: calls, getSession: { _, _ in makeRoot() })
    let store = makeStore(initial, client: client, uuid: .incrementing())

    await store.send(.requestAnswerChanged("One"))
    await store.send(.requestBarSendTapped)
    #expect(store.state.requestDock.page(for: form.id) == 1)
    #expect(store.state.composer.draft == "Chat draft")
    await store.send(.requestAnswerChanged("Two"))
    await store.send(.requestBarSendTapped)
    await settle(store)
    #expect(store.state.composer.draft == "Chat draft")
    #expect(calls.prompts.all.isEmpty)
    #expect(store.state.requests.respondingIDs.contains(form.id) || store.state.requests.forms.isEmpty)
    initial = store.state
    #expect(initial.composer.draft == "Chat draft")
  }

  @Test("the request bar denies a permission with the typed reason")
  func requestDockPermission() async {
    let calls = Calls()
    let permission = PermissionRequest(
      id: "perm",
      sessionID: "root",
      action: "bash",
      resources: ["rm -rf build"],
      save: ["bash"]
    )
    var requests = SessionRequests()
    requests.permissions = [permission]
    requests.selectedID = permission.id
    let client = client(calls: calls, getSession: { _, _ in makeRoot() })
    let store = makeStore(
      state(draft: "chat", requests: requests),
      client: client,
      uuid: .incrementing()
    )
    await store.send(.requestAnswerChanged("use a safer command"))
    await store.send(.requestBarSendTapped)
    await settle(store)
    #expect(calls.replies.all.count == 1)
    #expect(calls.replies.all.first?.1 == .reject)
    #expect(calls.replies.all.first?.2 == "use a safer command")
    #expect(calls.prompts.all.isEmpty)
    #expect(store.state.composer.draft == "chat")
  }


  @Test("a hidden conditional answer is pruned before a dock submission")
  func hiddenAnswerPruned() async {
    let calls = Calls()
    let answers = FormAnswerRecorder()
    let form = FormRequest(
      id: "conditional",
      sessionID: "root",
      title: "Conditional",
      fields: [
        FormField(
          key: "mode",
          type: .string,
          title: "Mode",
          options: [
            FormOption(value: "a", label: "A"),
            FormOption(value: "b", label: "B"),
          ]
        ),
        FormField(
          key: "detail",
          type: .string,
          title: "Detail",
          conditions: [FormCondition(key: "mode", op: .eq, value: .string("a"))]
        ),
      ],
      metadata: ["kind": .string("question")]
    )
    var requests = SessionRequests()
    requests.forms = [form]
    requests.answers = [form.id: form.defaultAnswers]
    requests.selectedID = form.id
    let client = client(
      calls: calls,
      getSession: { _, _ in makeRoot() },
      replyForm: { _, _, _, answer, _ in
        answers.append(answer)
        return .settled
      }
    )
    let store = makeStore(
      state(requests: requests),
      client: client,
      uuid: .incrementing()
    )
    await store.send(.requestValueChanged(formID: form.id, key: "mode", value: .string("b")))
    await store.send(.requestBarSendTapped)
    await settle(store)
    #expect(answers.all.first == ["mode": .string("b")])
    #expect(answers.all.first?["detail"] == nil)
  }


  @Test("subagent pages own distinct drafts and quotes, and sending targets the child")
  func subagentDraftOwnership() async {
    let root = makeRoot()
    let child1 = OpenCodeSession(
      id: "child-1", serverTitle: "Child 1", projectID: "p1",
      directory: "/work/opencode", updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
      parentID: "root"
    )
    let child2 = OpenCodeSession(
      id: "child-2", serverTitle: "Child 2", projectID: "p1",
      directory: "/work/opencode", updatedAt: Date(timeIntervalSince1970: 1_700_000_200),
      parentID: "root"
    )
    let family = [root, child1, child2]
    let calls = Calls()
    let client = client(
      calls: calls,
      getSession: { _, id in family.first { $0.id == id } ?? root },
      family: { _, _ in SessionFamily(root: root, sessions: family) }
    )
    let draftStore = ComposerDraftStore(
      storage: OpenCodeCore.InMemoryStorage(),
      storageKey: "drafts"
    )
    var initial = state(draft: "Root draft", familySessions: family)
    initial.composer.quotes = [ComposerQuote(id: "root-q", text: "root quote")]
    let store = makeStore(
      initial,
      client: client,
      uuid: .incrementing(),
      draftClient: .live(store: draftStore)
    )

    await store.send(.openSubagent("child-1"))
    await settle(store)
    #expect(store.state.composer.target == .session(id: "child-1"))
    #expect(store.state.composer.draft.isEmpty)
    await store.send(.composer(.textChanged("Child one draft")))
    await store.send(.composer(.quoteInserted(text: "child one quote")))
    await store.send(.composer(.flush))
    await settle(store)

    await store.send(.openSubagent("child-2"))
    await settle(store)
    #expect(store.state.composer.target == .session(id: "child-2"))
    #expect(store.state.composer.draft.isEmpty)
    await store.send(.composer(.textChanged("Child two draft")))
    await store.send(.composer(.flush))
    await settle(store)

    await store.send(.popPage)
    await settle(store)
    #expect(store.state.composer.target == .session(id: "child-1"))
    #expect(store.state.composer.draft == "Child one draft")
    #expect(store.state.composer.quotes.first?.text == "child one quote")

    await store.send(.composer(.sendTapped))
    await settle(store)
    #expect(calls.prompts.all.first?.0 == "child-1")
    #expect(calls.prompts.all.first?.1.text.contains("Child one draft") == true)

    await store.send(.popPage)
    await settle(store)
    #expect(store.state.composer.target == .session(id: "root"))
    #expect(store.state.composer.draft == "Root draft")
    #expect(store.state.composer.quotes.first?.text == "root quote")
  }


  @Test("a stored outbound found after reopening settles as accepted without a second prompt")
  func restartConfirmedAcceptance() async {
    let storage = OpenCodeCore.InMemoryStorage()
    let draftStore = ComposerDraftStore(storage: storage, storageKey: "drafts")
    let key = ComposerDraftKey(serverID: server.persistenceID, scope: .session("root"))
    _ = await draftStore.save(
      ComposerDraft(
        outbound: [
          ComposerOutbound(
            target: .session(id: "root"),
            messageID: "old-id",
            text: "Recovered",
            quotes: [],
            delivery: .steer,
            revision: 1
          )
        ],
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      for: key
    )
    let calls = Calls()
    let client = client(
      calls: calls,
      getSession: { _, _ in makeRoot() },
      message: { _, _, id in [.userText(id: id, text: "Recovered", source: nil, quotes: [])] },
      inputs: { _, _ in [] }
    )
    let store = makeStore(
      state(),
      client: client,
      uuid: .incrementing(),
      draftClient: .live(store: draftStore)
    )
    await store.send(.composer(.task))
    await settle(store)
    #expect(store.state.composer.failedSends.count == 1)
    #expect(store.state.composer.failedSends.first?.failure == .ambiguous)

    await store.send(.composer(.retryFailed(messageID: "old-id")))
    await settle(store)
    #expect(calls.prompts.all.isEmpty)
    #expect(store.state.composer.failedSends.isEmpty)
  }

  @Test("a stored outbound confirmed absent after reopening retries with a new id")
  func restartConfirmedAbsence() async {
    let storage = OpenCodeCore.InMemoryStorage()
    let draftStore = ComposerDraftStore(storage: storage, storageKey: "drafts")
    let key = ComposerDraftKey(serverID: server.persistenceID, scope: .session("root"))
    _ = await draftStore.save(
      ComposerDraft(
        outbound: [
          ComposerOutbound(
            target: .session(id: "root"),
            messageID: "old-id",
            text: "Recovered",
            quotes: [],
            delivery: .steer,
            revision: 1
          )
        ],
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      for: key
    )
    let calls = Calls()
    let newID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let client = client(
      calls: calls,
      getSession: { _, _ in makeRoot() },
      message: { _, _, _ in [] },
      inputs: { _, _ in [] }
    )
    let store = makeStore(
      state(),
      client: client,
      uuid: UuidClient { UUID(uuidString: newID)! },
      draftClient: .live(store: draftStore)
    )
    await store.send(.composer(.task))
    await settle(store)
    await store.send(.composer(.retryFailed(messageID: "old-id")))
    await settle(store)
    #expect(calls.prompts.all.map(\.1.id) == [newID])
    #expect(store.state.composer.failedSends.isEmpty)
  }


  @Test("a send completing after navigating away cannot alter the visible page draft")
  func sendCompletesOnAnotherPage() async {
    let root = makeRoot()
    let child = OpenCodeSession(
      id: "child-1", serverTitle: "Child 1", projectID: "p1",
      directory: "/work/opencode", updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
      parentID: "root"
    )
    let family = [root, child]
    let gate = Gate()
    let calls = Calls()
    let client = client(
      calls: calls,
      getSession: { _, id in family.first { $0.id == id } ?? root },
      family: { _, _ in SessionFamily(root: root, sessions: family) },
      send: { _, _, _ in await gate.wait() }
    )
    let draftStore = ComposerDraftStore(
      storage: OpenCodeCore.InMemoryStorage(),
      storageKey: "drafts"
    )
    let store = makeStore(
      state(draft: "Root draft", familySessions: family),
      client: client,
      uuid: .incrementing(),
      draftClient: .live(store: draftStore)
    )

    await store.send(.openSubagent("child-1"))
    await settle(store)
    await store.send(.composer(.textChanged("Child send")))
    await store.send(.composer(.sendTapped))
    #expect(await waitUntilPumping(store) { calls.prompts.all.count == 1 })

    await store.send(.popPage)
    #expect(await waitUntilPumping(store) { store.state.composer.target == .session(id: "root") })
    #expect(store.state.composer.draft == "Root draft")

    await gate.release()
    await settle(store)
    #expect(store.state.composer.draft == "Root draft")
    #expect(store.state.composer.failedSends.isEmpty)
    let childKey = ComposerDraftKey(serverID: server.persistenceID, scope: .session("child-1"))
    let persisted = await draftStore.load(childKey)
    guard case .found(let record) = persisted else {
      Issue.record("expected the child draft record")
      return
    }
    #expect(record.outbound.isEmpty)
    #expect(record.text.isEmpty)
  }


  @Test("a transcript quote enters the composer without replacing its draft")
  func quoteHandoff() async {
    let calls = Calls()
    let client = client(calls: calls, getSession: { _, _ in makeRoot() })
    let store = makeStore(
      state(draft: "Keep my words"),
      client: client,
      uuid: .incrementing()
    )
    await store.send(.transcriptQuoteTapped("quoted line"))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.composer.draft == "Keep my words")
    #expect(store.state.composer.quotes.first?.text == "quoted line")
  }
}


private func makeRoot() -> OpenCodeSession {
  OpenCodeSession(
    id: "root",
    serverTitle: "Root",
    projectID: "p1",
    directory: "/work/opencode",
    updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
  )
}
