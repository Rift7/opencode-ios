import ComposableArchitecture
import Foundation
import OpenCodeComposer
import OpenCodeCore
import OpenCodeServer
import OpenCodeTestSupport
import Synchronization
import Testing

@MainActor
@Suite("Composer", .serialized)
struct ComposerFeatureTests {
  private actor DraftBackend {
    var drafts: [String: ComposerDraft] = [:]
    var saves = 0
    var saveResult: ComposerDraftSave = .saved
    var loadResult: ComposerDraftLoad?

    func load(_ key: ComposerDraftKey) -> ComposerDraftLoad {
      if let loadResult { return loadResult }
      return drafts[key.storageKey].map(ComposerDraftLoad.found) ?? .missing
    }

    func save(_ draft: ComposerDraft, key: ComposerDraftKey) -> ComposerDraftSave {
      saves += 1
      if case .saved = saveResult {
        drafts[key.storageKey] = draft
      }
      return saveResult
    }

    func remove(_ key: ComposerDraftKey) -> ComposerDraftSave {
      drafts[key.storageKey] = nil
      return saveResult
    }

    func stored(_ key: ComposerDraftKey) -> ComposerDraft? { drafts[key.storageKey] }
    func saveCount() -> Int { saves }
    func setSave(_ result: ComposerDraftSave) { saveResult = result }
    func setLoad(_ result: ComposerDraftLoad?) { loadResult = result }
  }

  private func client(
    _ backend: DraftBackend,
    clock: ClockClient = .testValue,
    uuid: UuidClient = .incrementing()
  ) -> ComposerDraftClient {
    ComposerDraftClient(
      load: { await backend.load($0) },
      save: { await backend.save($0, key: $1) },
      remove: { await backend.remove($0) },
      flush: {}
    )
  }

  private func makeStore(
    state: ComposerFeature.State,
    backend: DraftBackend,
    clock: ClockClient = .testValue,
    uuid: UuidClient = .incrementing()
  ) -> TestStoreOf<ComposerFeature> {
    let store = TestStore(initialState: state) {
      ComposerFeature()
    } withDependencies: {
      $0.composerDrafts = client(backend, clock: clock, uuid: uuid)
      $0.clock = clock
      $0.uuidClient = uuid
      $0.dateClient = DateClient { Date(timeIntervalSince1970: 1_700_000_000) }
      $0.haptics = .testValue
    }
    store.exhaustivity = .off
    return store
  }


  private func makeStore(
    state: ComposerFeature.State,
    draftClient: ComposerDraftClient,
    uuid: UuidClient = .incrementing()
  ) -> TestStoreOf<ComposerFeature> {
    let store = TestStore(initialState: state) {
      ComposerFeature()
    } withDependencies: {
      $0.composerDrafts = draftClient
      $0.clock = .testValue
      $0.uuidClient = uuid
      $0.dateClient = DateClient { Date(timeIntervalSince1970: 1_700_000_000) }
      $0.haptics = .testValue
    }
    store.exhaustivity = .off
    return store
  }

  private func state(session: String = "session-1") -> ComposerFeature.State {
    ComposerFeature.State(
      serverID: "server-1",
      target: .session(id: session)
    )
  }

  private func settle(_ store: TestStoreOf<ComposerFeature>) async {
    for _ in 0..<8 {
      await store.finish()
      await store.skipReceivedActions(strict: false)
    }
  }

  private func waitUntil(
    _ condition: @escaping () async -> Bool,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
  }

  @Test("a draft restores when the field is still untouched, scoped per session")
  func draftRestorationAndIsolation() async {
    let backend = DraftBackend()
    let first = state(session: "a")
    let second = state(session: "b")
    let keyA = first.draftKey
    let keyB = second.draftKey
    await backend.setLoad(.found(ComposerDraft(text: "A draft")))
    let storeA = makeStore(state: first, backend: backend)
    await storeA.send(.task)
    await settle(storeA)
    await storeA.send(.flush)
    await settle(storeA)
    #expect(storeA.state.draft == "A draft")

    await backend.setLoad(nil)
    let storeB = makeStore(state: second, backend: backend)
    await storeB.send(.task)
    await settle(storeB)
    #expect(storeB.state.draft.isEmpty)
    await storeB.send(.textChanged("B draft"))
    await storeB.send(.flush)
    await settle(storeB)
    #expect(await backend.stored(keyA)?.text == "A draft")
    #expect(await backend.stored(keyB)?.text == "B draft")
  }

  @Test("a delayed restoration never overwrites newer typing")
  func delayedRestorationLosesToTyping() async {
    let backend = DraftBackend()
    let gate = Gate()
    let key = state().draftKey
    await backend.setLoad(.found(ComposerDraft(text: "older")))
    let draftClient = ComposerDraftClient(
      load: { _ in
        await gate.wait()
        return .found(ComposerDraft(text: "older"))
      },
      save: { draft, key in await backend.save(draft, key: key) },
      remove: { await backend.remove($0) },
      flush: {}
    )
    let store = TestStore(initialState: state()) {
      ComposerFeature()
    } withDependencies: {
      $0.composerDrafts = draftClient
      $0.clock = .testValue
      $0.uuidClient = .incrementing()
      $0.haptics = .testValue
    }
    store.exhaustivity = .off

    await store.send(.task)
    await store.send(.textChanged("newer"))
    await gate.open()
    await settle(store)
    #expect(store.state.draft == "newer")
    #expect((await backend.stored(key)?.text ?? "newer") != "older")
  }

  @Test("a failed save is reported and keeps the text")
  func failedSaveIsReported() async {
    let backend = DraftBackend()
    await backend.setSave(.failure(.unavailable))
    let clock = ClockClient.recording()
    let store = makeStore(state: state(), backend: backend, clock: clock.client)
    await store.send(.task)
    await settle(store)
    await store.send(.textChanged("keep me"))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.draft == "keep me")
    #expect(store.state.problem == ComposerProblem.couldNotSave)
  }

  @Test("a draft over the bound is reported, never truncated")
  func tooLargeDraft() async {
    let backend = DraftBackend()
    let store = makeStore(state: state(), backend: backend)
    let large = String(repeating: "a", count: ComposerDraftBounds.maximumTextBytes + 1)
    await store.send(.textChanged(large))
    await store.send(.flush)
    await settle(store)
    #expect(store.state.draft.count == large.count)
    #expect(store.state.problem == .draftTooLarge)
    #expect(await backend.saveCount() == 0)
  }

  @Test("a send is admitted once and carries a stable message id")
  func duplicateSendTapSendsOnce() async {
    let backend = DraftBackend()
    let fixedID = "11111111-1111-4111-8111-111111111111"
    let uuid = UuidClient { UUID(uuidString: fixedID)! }
    let store = makeStore(state: state(), backend: backend, uuid: uuid)
    await store.send(.task)
    await settle(store)
    await store.send(.textChanged("Hello"))
    let expectedID = fixedID
    await store.send(.sendTapped)
    await store.receive(
      .delegate(
        .send(
          ComposerSend(
            target: .session(id: "session-1"),
            messageID: expectedID,
            text: "Hello",
            quotes: [],
            delivery: .steer,
            revision: 1
          )
        )
      )
    )
    #expect(store.state.isSending)
    #expect(store.state.draft.isEmpty)
    await store.send(.sendTapped)
    await store.send(.queueTapped)
    #expect(store.state.isSending)
  }

  @Test("a completed send leaves text typed after it alone")
  func newerTypingSurvivesSendCompletion() async {
    let backend = DraftBackend()
    let store = makeStore(state: state(), backend: backend)
    await store.send(.task)
    await settle(store)
    await store.send(.textChanged("First"))
    await store.send(.sendTapped)
    await store.skipReceivedActions(strict: false)
    await store.send(.textChanged("Second"))
    let messageID = store.state.outbound.first?.messageID ?? ""
    await store.send(.sendAccepted(messageID: messageID))
    #expect(store.state.draft == "Second")
    #expect(!store.state.isSending)
  }

  @Test("an unverified send keeps its optimistic identity and clears sending")
  func unverifiedSend() async {
    let backend = DraftBackend()
    let fixedID = "55555555-5555-4555-8555-555555555555"
    let store = makeStore(
      state: state(),
      backend: backend,
      uuid: UuidClient { UUID(uuidString: fixedID)! }
    )
    await store.send(.task)
    await settle(store)
    await store.send(.textChanged("Maybe"))
    await store.send(.sendTapped)
    await store.skipReceivedActions(strict: false)
    await store.send(.sendUnverified(messageID: fixedID))
    #expect(!store.state.isSending)
    #expect(store.state.draft.isEmpty)
    #expect(store.state.problem == .couldNotVerifySend)
    #expect(store.state.failedSends.count == 1)
    #expect(store.state.failedSends.first?.failure == .ambiguous)
    #expect(store.state.failedSends.first?.text == "Maybe")
    #expect(store.state.failedSends.first?.messageID == fixedID)
    await store.send(.editFailed(messageID: fixedID))
    #expect(store.state.draft.isEmpty)
    #expect(store.state.failedSends.count == 1)
  }

  @Test("a confirmed failure restores the text when nothing newer was typed")
  func failureRestoresDraft() async {
    let backend = DraftBackend()
    let fixedID = "33333333-3333-4333-8333-333333333333"
    let store = makeStore(state: state(), backend: backend, uuid: UuidClient { UUID(uuidString: fixedID)! })
    await store.send(.task)
    await settle(store)
    await store.send(.textChanged("Keep this"))
    await store.send(.sendTapped)
    await store.skipReceivedActions(strict: false)
    await store.send(.sendFailed(messageID: fixedID, failure: .definite))
    #expect(store.state.draft == "Keep this")
    #expect(store.state.problem == .couldNotSend)
    #expect(store.state.failedSends.isEmpty)
  }

  @Test("a failure with newer text keeps both, and Edit merges the failed message")
  func failureWithNewerTyping() async {
    let backend = DraftBackend()
    let fixedID = "44444444-4444-4444-8444-444444444444"
    let store = makeStore(state: state(), backend: backend, uuid: UuidClient { UUID(uuidString: fixedID)! })
    await store.send(.task)
    await settle(store)
    await store.send(.textChanged("Old"))
    await store.send(.sendTapped)
    await store.skipReceivedActions(strict: false)
    await store.send(.textChanged("New"))
    await store.send(.sendFailed(messageID: fixedID, failure: .definite))
    #expect(store.state.draft == "New")
    #expect(store.state.failedSends.count == 1)
    await store.send(.editFailed(messageID: fixedID))
    #expect(store.state.draft == "Old\n\nNew")
  }


  @Test("a save failure at Send does not dispatch and keeps the editor text")
  func sendPersistenceFailureKeepsText() async {
    let backend = DraftBackend()
    let fixedID = "66666666-6666-4666-8666-666666666666"
    await backend.setSave(.failure(.unavailable))
    let store = makeStore(
      state: state(),
      backend: backend,
      uuid: UuidClient { UUID(uuidString: fixedID)! }
    )
    await store.send(.task)
    await settle(store)
    await store.send(.textChanged("Keep offline"))
    await store.send(.sendTapped)
    await settle(store)
    #expect(store.state.draft == "Keep offline")
    #expect(store.state.outbound.isEmpty)
    #expect(!store.state.isSending)
    #expect(store.state.problem == ComposerProblem.couldNotSave)
  }

  @Test("a blocked send restores the outbound text and settles the composer")
  func blockedSendRestores() async {
    let backend = DraftBackend()
    let fixedID = "77777777-7777-4777-8777-777777777777"
    let store = makeStore(
      state: state(),
      backend: backend,
      uuid: UuidClient { UUID(uuidString: fixedID)! }
    )
    await store.send(.task)
    await settle(store)
    await store.send(.textChanged("Offline message"))
    await store.send(.sendTapped)
    await settle(store)
    await store.send(.sendBlocked(.notConnected))
    await settle(store)
    #expect(store.state.draft == "Offline message")
    #expect(store.state.outbound.isEmpty)
    #expect(!store.state.isSending)
    #expect(store.state.failedSends.isEmpty)
    let key = state().draftKey
    #expect(await backend.stored(key)?.text == "Offline message")
    #expect(await backend.stored(key)?.outbound.isEmpty == true)
  }

  @Test("a request arriving before dispatch restores the outbound text")
  func requestBlockedSendRestores() async {
    let backend = DraftBackend()
    let fixedID = "88888888-8888-4888-8888-888888888888"
    let store = makeStore(
      state: state(),
      backend: backend,
      uuid: UuidClient { UUID(uuidString: fixedID)! }
    )
    await store.send(.task)
    await settle(store)
    await store.send(.textChanged("Answer later"))
    await store.send(.sendTapped)
    await settle(store)
    await store.send(.sendBlocked(.requestPending))
    await settle(store)
    #expect(store.state.draft == "Answer later")
    #expect(store.state.problem == .requestPending)
    #expect(store.state.outbound.isEmpty)
  }

  @Test("an unresolved outbound record survives restart as an unverified send with its id")
  func restartAfterSendBeforeResponse() async {
    let storage = OpenCodeCore.InMemoryStorage()
    let draftStore = ComposerDraftStore(storage: storage, storageKey: "drafts")
    let client = ComposerDraftClient.live(store: draftStore)
    let fixedID = "99999999-9999-4999-8999-999999999999"
    let first = makeStore(
      state: state(),
      draftClient: client,
      uuid: UuidClient { UUID(uuidString: fixedID)! }
    )
    await first.send(.task)
    await settle(first)
    await first.send(.textChanged("Survive this"))
    await first.send(.sendTapped)
    await settle(first)
    #expect(first.state.outbound.count == 1)

    let reopened = makeStore(state: state(), draftClient: client)
    await reopened.send(.task)
    await settle(reopened)
    #expect(reopened.state.draft.isEmpty)
    #expect(reopened.state.failedSends.count == 1)
    #expect(reopened.state.failedSends.first?.messageID == fixedID)
    #expect(reopened.state.failedSends.first?.text == "Survive this")
    #expect(reopened.state.failedSends.first?.failure == .ambiguous)
    let stored = await draftStore.load(state().draftKey)
    guard case .found(let record) = stored else {
      Issue.record("expected a stored draft")
      return
    }
    #expect(record.outbound.isEmpty)
    #expect(record.failedSends.count == 1)
  }


  @Test("migration failures are surfaced without dropping the composer target")
  func migrationFailuresSurface() async {
    let backend = DraftBackend()
    let initial = state(session: "new-session")
    let store = makeStore(state: initial, backend: backend)
    await store.send(.task)
    await settle(store)
    let oldKey = ComposerDraftKey(
      serverID: "server-1",
      scope: .newSession(directory: "/work/box")
    )
    let newKey = ComposerDraftKey(serverID: "server-1", scope: .session("new-session"))
    await store.send(
      .migrationFinished(
        result: .destinationFailed(.unavailable),
        draft: initial.persistedDraft,
        oldKey: oldKey,
        newKey: newKey
      )
    )
    #expect(store.state.problem == .couldNotSave)
    await store.send(
      .migrationFinished(
        result: .sourceRetained(.unavailable),
        draft: initial.persistedDraft,
        oldKey: oldKey,
        newKey: newKey
      )
    )
    #expect(store.state.problem == .couldNotCleanUpDraft)
    #expect(store.state.target == .session(id: "new-session"))
  }

  @Test("switching targets preserves distinct drafts and quotes")
  func switchTargetPreservesDrafts() async {
    let storage = OpenCodeCore.InMemoryStorage()
    let draftStore = ComposerDraftStore(storage: storage, storageKey: "drafts")
    let client = ComposerDraftClient.live(store: draftStore)
    let store = makeStore(state: state(session: "a"), draftClient: client)
    await store.send(.task)
    await settle(store)
    await store.send(.textChanged("A draft"))
    await store.send(.quoteInserted(text: "A quote"))
    await store.send(.flush)
    await settle(store)

    await store.send(.switchTarget(.session(id: "b")))
    await settle(store)
    #expect(store.state.target == .session(id: "b"))
    #expect(store.state.draft.isEmpty)
    await store.send(.textChanged("B draft"))
    await store.send(.flush)
    await settle(store)

    await store.send(.switchTarget(.session(id: "a")))
    await settle(store)
    #expect(store.state.draft == "A draft")
    #expect(store.state.quotes.first?.text == "A quote")

    await store.send(.switchTarget(.session(id: "b")))
    await settle(store)
    #expect(store.state.draft == "B draft")
  }


  @Test("quotes become a model block and metadata comments without changing the chat draft")
  func quotePromptAndDraftPreservation() async {
    let backend = DraftBackend()
    let fixedID = "11111111-1111-4111-8111-111111111111"
    let uuid = UuidClient { UUID(uuidString: fixedID)! }
    let store = makeStore(state: state(), backend: backend, uuid: uuid)
    await store.send(.task)
    await settle(store)
    await store.send(.textChanged("Explain this"))
    await store.send(.quoteInserted(text: "selected words"))
    let quoteID = store.state.quotes[0].id
    await store.send(.quoteCommentChanged(id: quoteID, comment: "my note"))
    #expect(store.state.draft == "Explain this")
    let expectedID = fixedID
    await store.send(.sendTapped)
    await store.receive(
      .delegate(
        .send(
          ComposerSend(
            target: .session(id: "session-1"),
            messageID: expectedID,
            text: "Explain this",
            quotes: [
              ComposerQuote(
                id: quoteID,
                text: "selected words",
                comment: "my note"
              )
            ],
            delivery: .steer,
            revision: 3
          )
        )
      )
    )
    let prompt = ComposerSend(
      target: .session(id: "session-1"),
      messageID: expectedID,
      text: "Explain this",
      quotes: [ComposerQuote(id: quoteID, text: "selected words", comment: "my note")],
      delivery: .steer,
      revision: 3
    ).prompt
    #expect(prompt.text.contains("> selected words"))
    #expect(prompt.text.contains("The user made the following comment regarding this quote: my note"))
    #expect(prompt.metadata?.comments?.first?.type == "quote")
    #expect(prompt.metadata?.displayText == "Explain this")
  }

  @Test("editor replacements shift or invalidate mention occurrences")
  func editorReplacementMaintainsMentions() async {
    var state = ComposerFeature.State(serverID: "server", target: .session(id: "s1"))
    state.draft = "Use @review"
    state.chips = [
      ComposerMentionChip(
        id: "skill:review",
        kind: .skill,
        value: "review",
        token: "@review",
        title: "review",
        occurrenceID: "one",
        start: 4,
        end: 11
      )
    ]
    let store = TestStore(initialState: state) {
      ComposerFeature()
    } withDependencies: {
      $0.composerDrafts = .testValue
      $0.clock = .testValue
      $0.dateClient = DateClient { Date(timeIntervalSince1970: 1_700_000_000) }
      $0.haptics = .testValue
    }
    store.exhaustivity = .off
    await store.send(.textChanged("1234 Use @review"))
    await store.send(
      .textEdited(
        oldText: "Use @review",
        newText: "1234 Use @review",
        range: NSRange(location: 0, length: 0),
        replacementLength: 4
      )
    )
    #expect(store.state.chips.first?.start == 8)

    await store.send(
      .textEdited(
        oldText: "1234 Use @review",
        newText: "1234 Use @revieX",
        range: NSRange(location: 12, length: 1),
        replacementLength: 1
      )
    )
    #expect(store.state.chips.isEmpty)
  }

  @Test("marked text closes suggestions instead of committing a query")
  func markedTextClosesAutocomplete() async {
    let store = TestStore(
      initialState: ComposerFeature.State(serverID: "server", target: .session(id: "s1"))
    ) {
      ComposerFeature()
    } withDependencies: {
      $0.composerDrafts = .testValue
      $0.clock = .testValue
      $0.dateClient = DateClient { Date(timeIntervalSince1970: 1_700_000_000) }
      $0.haptics = .testValue
    }
    store.exhaustivity = .off
    await store.send(.textChanged("@re"))
    #expect(store.state.autocomplete.trigger?.query == "re")
    await store.send(.caretChanged(text: "@re", caret: 3, isComposing: true))
    #expect(store.state.autocomplete.trigger == nil)
    #expect(store.state.autocomplete.suggestions.isEmpty)
  }
}

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
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }
}
