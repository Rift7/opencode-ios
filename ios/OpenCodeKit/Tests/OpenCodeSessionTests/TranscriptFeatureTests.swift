import ComposableArchitecture
import Foundation
import OpenCodeCore
import OpenCodeServer
import OpenCodeSession
import OpenCodeTranscript
import Synchronization
import Testing

@MainActor
@Suite("Transcript in the session", .serialized)
struct TranscriptFeatureTests {
  private let server = OpenCodeServer(
    url: "http://127.0.0.1:4110",
    username: "opencode",
    password: "test-token"
  )

  nonisolated private func root(_ id: String = "root") -> OpenCodeSession {
    OpenCodeSession(
      id: id,
      serverTitle: "Root",
      projectID: "p1",
      directory: "/work/opencode",
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  nonisolated private func child(_ id: String) -> OpenCodeSession {
    OpenCodeSession(
      id: id,
      serverTitle: id,
      projectID: "p1",
      directory: "/work/opencode",
      updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
      parentID: "root"
    )
  }

  private func state(_ root: OpenCodeSession? = nil) -> SessionFeature.State {
    SessionFeature.State(
      id: 1,
      server: server,
      selection: SessionSelection(
        serverID: server.persistenceID,
        sessionID: "root",
        intent: .browse
      ),
      session: root ?? self.root()
    )
  }

  private func makeStore(
    _ state: SessionFeature.State,
    client: OpenCodeClient,
    clock: ClockClient = .testValue,
    pasteboard: PasteboardClient = .testValue,
    linkOpener: OpenURLClient = OpenURLClient { _ in true }
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
      $0.pasteboard = pasteboard
      $0.linkOpener = linkOpener
    }
    store.exhaustivity = .off
    return store
  }

  private func client(
    getSession: @escaping @Sendable (OpenCodeServer, String) async throws -> OpenCodeSession,
    family: @escaping @Sendable (OpenCodeServer, OpenCodeSession) async throws -> SessionFamily = {
      _, root in SessionFamily(root: root, sessions: [root])
    },
    transcript: @escaping @Sendable (OpenCodeServer, String, Int) async throws -> TranscriptPage = {
      _, _, _ in TranscriptPage(items: [])
    },
    history: @escaping @Sendable (OpenCodeServer, String, String?) async throws -> TranscriptPage = {
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
      pendingInputs: { _, _ in [] },
      transcript: transcript,
      transcriptHistory: history,
      events: { _, _ in AsyncThrowingStream { $0.finish() } }
    )
  }

  private func settle(_ store: TestStoreOf<SessionFeature>) async {
    for _ in 0..<12 {
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

  nonisolated private func user(_ id: String) -> TranscriptItem {
    .userText(id: id, text: id, source: nil, quotes: [])
  }

  nonisolated private func reply(_ id: String) -> TranscriptItem {
    .assistantMarkdown(id: id, text: "Reply \(id)", inProgress: false)
  }

  @Test("the session's authoritative read carries the transcript on the same request identity")
  func readPlan() async {
    let page = TranscriptPage(items: [user("u1"), reply("a1")], next: nil)
    let store = makeStore(
      state(),
      client: client(getSession: { _, _ in self.root() }, transcript: { _, _, _ in page })
    )
    await store.send(.task)
    await settle(store)
    #expect(store.state.transcripts["root"]?.items.map(\.id) == ["u1", "a1"])
    #expect(store.state.activeTranscript?.entries.count == 3)
    #expect(store.state.activeTranscript?.showsEmptyState == false)
  }

  @Test("an empty complete transcript reaches the empty state, and a failed first read has a typed problem")
  func emptyAndFailure() async {
    let empty = makeStore(
      state(),
      client: client(getSession: { _, _ in self.root() }, transcript: { _, _, _ in TranscriptPage(items: []) })
    )
    await empty.send(.task)
    await settle(empty)
    #expect(empty.state.activeTranscript?.showsEmptyState == true)

    let failing = makeStore(
      state(),
      client: client(
        getSession: { _, _ in self.root() },
        transcript: { _, _, _ in throw OpenCodeClientError(.status(500)) }
      )
    )
    await failing.send(.task)
    await settle(failing)
    #expect(failing.state.activeTranscript?.problem == .serverStatus(500))
    #expect(failing.state.activeTranscript?.items.isEmpty == true)
  }

  @Test("live deltas project immediately and the durable boundary still settles from REST")
  func liveAndSettlement() async {
    let clock = ClockClient.recording()
    let reads = CallCounter()
    let durable = user("u1")
    let streamed = TranscriptItem.assistantMarkdown(
      id: "m1-text-0",
      text: "Hello world",
      inProgress: false
    )
    let store = makeStore(
      state(),
      client: client(
        getSession: { _, _ in self.root() },
        transcript: { _, _, _ in
          let count = await reads.count("reads")
          await reads.increment("reads")
          return TranscriptPage(items: count == 0 ? [durable] : [durable, streamed], next: nil)
        }
      ),
      clock: clock.client
    )
    await store.send(.task)
    await settle(store)

    await store.send(
      .serverEvent(
        .contentBatch(
          sessionID: "root",
          events: [
            .textStarted(messageID: "m1", ordinal: 0),
            .textDelta(messageID: "m1", ordinal: 0, delta: "Hello ", accumulatedText: nil),
            .textDelta(messageID: "m1", ordinal: 0, delta: "world", accumulatedText: nil),
          ]
        )
      )
    )
    #expect(
      store.state.activeTranscript?.items.contains {
        if case .assistantMarkdown(_, let text, let progress) = $0 {
          return text == "Hello world" && progress
        }
        return false
      } == true
    )

    let before = await reads.count("reads")
    await store.send(.serverEvent(.contentBatch(sessionID: "root", events: [
      .textEnded(messageID: "m1", ordinal: 0, text: "Hello world"),
    ])))
    await settle(store)
    #expect(clock.sleeps.contains(.milliseconds(200)))
    #expect(await reads.count("reads") > before)
    // The REST window has no m1: the in-progress row was replaced by its durable text and kept.
    #expect(store.state.activeTranscript?.items.contains(where: { $0.id == "m1-text-0" }) == true)
  }

  @Test("an event racing a snapshot is replayed after the window")
  func eventRace() async {
    let gate = Gate()
    let page = TranscriptPage(items: [user("u1")], next: nil)
    let store = makeStore(
      state(),
      client: client(
        getSession: { _, _ in
          await gate.wait()
          return self.root()
        },
        transcript: { _, _, _ in page }
      )
    )
    await store.send(.task)
    #expect(await waitUntil { store.state.refresh != nil })
    await store.send(
      .serverEvent(
        .contentBatch(
          sessionID: "root",
          events: [.textStarted(messageID: "m9", ordinal: 0),
            .textDelta(messageID: "m9", ordinal: 0, delta: "late", accumulatedText: nil)]
        )
      )
    )
    // Queued, not applied over a window that has not landed yet.
    #expect(store.state.activeTranscript?.items.isEmpty == true)
    await gate.open()
    await settle(store)
    #expect(store.state.activeTranscript?.items.contains(where: { $0.id == "m9-text-0" }) == true)
  }

  @Test("a queued older delta cannot overwrite the durable text a snapshot settled")
  func staleDeltaAfterSnapshot() async {
    let gate = Gate()
    let durable = TranscriptItem.assistantMarkdown(
      id: "m-text-0",
      text: "settled",
      inProgress: false
    )
    let client = client(
      getSession: { _, _ in
        await gate.wait()
        return self.root()
      },
      transcript: { _, _, _ in TranscriptPage(items: [durable]) }
    )
    let store = makeStore(state(), client: client)
    await store.send(.task)
    #expect(await waitUntil { store.state.refresh != nil })
    await store.send(
      .serverEvent(
        .contentBatch(
          sessionID: "root",
          events: [
            .textStarted(messageID: "m", ordinal: 0),
            .textDelta(messageID: "m", ordinal: 0, delta: "stale", accumulatedText: nil),
          ]
        )
      )
    )
    await gate.open()
    await settle(store)
    guard case .assistantMarkdown(_, let text, let inProgress)? =
      store.state.activeTranscript?.items.first(where: { $0.id == "m-text-0" })
    else {
      Issue.record("expected durable row")
      return
    }
    #expect(text == "settled")
    #expect(!inProgress)
  }

  @Test("a message invalidation re-reads through the same refresh queue")
  func invalidationReads() async {
    let reads = CallCounter()
    let store = makeStore(
      state(),
      client: client(
        getSession: { _, _ in self.root() },
        transcript: { _, _, _ in
          await reads.increment("reads")
          return TranscriptPage(items: [user("u1")], next: nil)
        }
      )
    )
    await store.send(.task)
    await settle(store)
    let before = await reads.count("reads")
    await store.send(.serverEvent(.messageInvalidated(sessionID: "root")))
    await settle(store)
    #expect(await reads.count("reads") > before)
  }

  @Test("earlier history pages by cursor, keeps order, and is exhausted at the start")
  func earlierHistory() async {
    let all = (0..<110).map { index -> TranscriptItem in
      index.isMultiple(of: 2) ? user("u\(index)") : reply("a\(index)")
    }
    let newest = Array(all.suffix(30))
    let older = Array(all.dropLast(30))
    let calls = CallCounter()
    let store = makeStore(
      state(),
      client: client(
        getSession: { _, _ in self.root() },
        transcript: { _, _, _ in TranscriptPage(items: newest, next: "c1") },
        history: { _, _, cursor in
          await calls.increment(cursor ?? "nil")
          return TranscriptPage(items: older, next: nil)
        }
      )
    )
    await store.send(.task)
    await settle(store)
    #expect(store.state.activeTranscript?.earlier == .paging(cursor: "c1"))
    #expect(store.state.activeTranscript?.items.count == 30)

    await store.send(.transcriptEarlierTapped)
    await settle(store)
    #expect(await calls.count("c1") == 1)
    #expect(store.state.activeTranscript?.items.map(\.id) == all.map(\.id))
    #expect(store.state.activeTranscript?.earlier == .exhausted)
    #expect(Set(store.state.activeTranscript?.items.map(\.id) ?? []).count == 110)
  }

  @Test("a failed earlier page keeps its cursor and retry loads it")
  func earlierRetry() async {
    let newest = (0..<30).map { user("newest-\($0)") }
    let older = (0..<20).map { user("older-\($0)") } + newest
    let failures = Counter(limit: 1)
    let store = makeStore(
      state(),
      client: client(
        getSession: { _, _ in self.root() },
        transcript: { _, _, _ in TranscriptPage(items: newest, next: "c1") },
        history: { _, _, _ in
          if await failures.take() {
            throw OpenCodeClientError(.transport(.timedOut))
          }
          return TranscriptPage(items: older, next: nil)
        }
      )
    )
    await store.send(.task)
    await settle(store)
    await store.send(.transcriptEarlierTapped)
    await settle(store)
    #expect(store.state.activeTranscript?.earlier == .paging(cursor: "c1"))
    #expect(store.state.activeTranscript?.earlierProblem == .timedOut)
    #expect(store.state.activeTranscript?.items.count == 30)

    await store.send(.transcriptEarlierTapped)
    await settle(store)
    #expect(store.state.activeTranscript?.items.count == 50)
    #expect(store.state.activeTranscript?.earlierProblem == nil)
    #expect(store.state.activeTranscript?.earlier == .exhausted)
  }

  @Test("a late earlier page is rejected after a new authoritative window invalidates its generation")
  func staleEarlierPage() async {
    let gate = Gate()
    let newest = (0..<30).map { user("newest-\($0)") }
    let replacement = (100..<130).map { user("replacement-\($0)") }
    let reads = CallCounter()
    let store = makeStore(
      state(),
      client: client(
        getSession: { _, _ in self.root() },
        transcript: { _, _, _ in
          await reads.increment("reads")
          if await reads.count("reads") > 1 {
            return TranscriptPage(items: replacement, next: "c2")
          }
          return TranscriptPage(items: newest, next: "c1")
        },
        history: { _, _, _ in
          await gate.wait()
          return TranscriptPage(items: (0..<20).map { user("old-\($0)") } + newest, next: nil)
        }
      )
    )
    await store.send(.task)
    await settle(store)
    await store.send(.transcriptEarlierTapped)
    #expect(await waitUntil { store.state.activeTranscript?.isLoadingEarlier == true })

    // A replacement window with no overlap bumps the generation while the page is in flight.
    await store.send(.refreshRequested(.invalidation))
    await settle(store)
    let generation = store.state.activeTranscript?.generation
    await gate.open()
    await settle(store)
    #expect(store.state.activeTranscript?.generation == generation)
    #expect(store.state.activeTranscript?.items.contains(where: { $0.id.hasPrefix("old-") }) == false)
  }

  @Test("a reconnect re-reads, and a lost connection cancels the earlier page")
  func reconnect() async {
    let reads = CallCounter()
    let gate = Gate()
    let newest = TranscriptPage(items: (0..<30).map { user("n-\($0)") }, next: "c1")
    let store = makeStore(
      state(),
      client: client(
        getSession: { _, _ in self.root() },
        transcript: { _, _, _ in
          await reads.increment("reads")
          return newest
        },
        history: { _, _, _ in
          await gate.wait()
          return TranscriptPage(items: [], next: nil)
        }
      )
    )
    await store.send(.task)
    await settle(store)
    let before = await reads.count("reads")
    await store.send(.connectionChanged(isConnected: false))
    await store.send(.connectionChanged(isConnected: true))
    await settle(store)
    #expect(await reads.count("reads") > before)
    #expect(store.state.activeTranscript?.isLoadingEarlier == false)

    let afterReconnect = await reads.count("reads")
    await store.send(.connectionResynchronized)
    await settle(store)
    #expect(await reads.count("reads") > afterReconnect)
    #expect(store.state.activeTranscript?.items.count == 30)
  }

  @Test("a subagent page keeps its own transcript and returns to the root's disclosures and position")
  func pageRestoration() async {
    let family = SessionFamily(
      root: root(),
      sessions: [root(), child("kid")],
      activeSessionIDs: []
    )
    let store = makeStore(
      state(),
      client: client(
        getSession: { _, id in id == "kid" ? self.child("kid") : self.root() },
        family: { _, _ in family },
        transcript: { _, id, _ in
          id == "kid"
            ? TranscriptPage(items: [user("kid-u"), reply("kid-a")])
            : TranscriptPage(items: [user("root-u"), reply("root-a"), reply("root-b")])
        }
      )
    )
    await store.send(.task)
    await settle(store)
    let rootDisclosure = store.state.activeTranscript?.entries.first(where: {
      if case .replyEnd = $0 { true } else { false }
    })?.id
    if let rootDisclosure {
      await store.send(.transcriptDisclosureToggled(rootDisclosure))
    }
    await store.send(.transcriptFollowChanged(sessionID: "root", isFollowing: false, anchorID: "root-a"))
    #expect(store.state.activeTranscript?.isFollowing == false)
    #expect(store.state.activeTranscript?.scrollAnchorID == "root-a")

    await store.send(.openSubagent("kid"))
    await settle(store)
    #expect(store.state.activeTranscript?.items.map(\.id) == ["kid-u", "kid-a"])
    #expect(store.state.transcripts["root"]?.items.count == 3)

    await store.send(.popPage)
    await settle(store)
    #expect(store.state.activeTranscript?.items.count == 3)
    if let rootDisclosure {
      #expect(store.state.activeTranscript?.isExpanded(rootDisclosure) == true)
    }
    #expect(store.state.activeTranscript?.scrollAnchorID == "root-a")
  }

  @Test("Copy goes through the pasteboard and a link opens only after confirmation")
  func copyAndLinks() async {
    let pasted = Mutex<[String]>([])
    let opened = Mutex<[String]>([])
    let pasteboard = PasteboardClient(
      string: { nil },
      setString: { text in pasted.withLock { $0.append(text) } }
    )
    let store = makeStore(
      state(),
      client: client(
        getSession: { _, _ in self.root() },
        transcript: { _, _, _ in TranscriptPage(items: [user("u1"), reply("a1")]) }
      ),
      pasteboard: pasteboard,
      linkOpener: OpenURLClient { url in
        opened.withLock { $0.append(url.absoluteString) }
        return true
      }
    )
    await store.send(.task)
    await settle(store)
    await store.send(.transcriptCopyTapped("copy me"))
    #expect(pasted.withLock { $0 } == ["copy me"])

    await store.send(.transcriptLinkTapped("https://example.com/a"))
    #expect(store.state.pendingLink?.absoluteString == "https://example.com/a")
    #expect(opened.withLock { $0 }.isEmpty)
    await store.send(.transcriptLinkConfirmed)
    await settle(store)
    #expect(opened.withLock { $0 } == ["https://example.com/a"])
    #expect(store.state.pendingLink == nil)

    await store.send(.transcriptLinkTapped("javascript:alert(1)"))
    #expect(store.state.pendingLink == nil)
  }

  @Test("a message invalidation racing a read earns one coalesced follow-up")
  func invalidationRacingRead() async {
    let gate = Gate()
    let reads = CallCounter()
    let stale = TranscriptPage(items: [reply("a-old")])
    let fresh = TranscriptPage(items: [user("u-new"), reply("a-new")])
    let store = makeStore(
      state(),
      client: client(
        getSession: { _, _ in self.root() },
        transcript: { _, _, _ in
          let count = await reads.count("reads")
          await reads.increment("reads")
          if count == 0 {
            await gate.wait()
            return stale
          }
          return fresh
        }
      )
    )
    await store.send(.task)
    #expect(await waitUntil { store.state.refresh != nil && store.state.transcripts["root"] != nil })
    #expect(await waitUntil { await reads.count("reads") == 1 })

    await store.send(.serverEvent(.messageInvalidated(sessionID: "root")))
    await store.send(.serverEvent(.messageInvalidated(sessionID: "root")))
    #expect(store.state.refresh?.followup == .invalidation)

    await gate.open()
    await settle(store)
    #expect(await reads.count("reads") == 2)
    #expect(store.state.activeTranscript?.items.map(\.id) == ["u-new", "a-new"])
    #expect(store.state.activeTranscript?.items.contains(where: { $0.id == "a-old" }) == false)
  }

  @Test("raced-event pressure marks the projection incomplete and rehydrates")
  func racedOverflowRehydrates() async {
    let gate = Gate()
    let reads = CallCounter()
    let fresh = TranscriptPage(
      items: [
        user("u1"),
        .assistantMarkdown(id: "m-text-0", text: "authoritative", inProgress: false),
        .tool(
          id: "m-tool-t1",
          call: TranscriptToolCall(
            callID: "t1",
            messageID: "m",
            name: "read",
            status: .completed,
            input: .object(["path": .string("a")]),
            output: ["final"]
          )
        ),
      ]
    )
    let store = makeStore(
      state(),
      client: client(
        getSession: { _, _ in self.root() },
        transcript: { _, _, _ in
          let count = await reads.count("reads")
          await reads.increment("reads")
          if count == 0 {
            await gate.wait()
            return TranscriptPage(items: [user("u1")])
          }
          return fresh
        }
      )
    )
    await store.send(.task)
    #expect(await waitUntil { store.state.refresh != nil })
    #expect(await waitUntil { await reads.count("reads") == 1 })

    for index in 0..<300 {
      await store.send(
        .serverEvent(
          .contentBatch(
            sessionID: "root",
            events: [
              .textDelta(
                messageID: "m",
                ordinal: 0,
                delta: "t\(index) ",
                accumulatedText: nil
              )
            ]
          )
        )
      )
    }
    for index in 0..<300 {
      await store.send(
        .serverEvent(
          .contentBatch(
            sessionID: "root",
            events: [.toolInputDelta(messageID: "m", toolID: "t1", delta: "x\(index)")]
          )
        )
      )
    }
    await store.send(.serverEvent(.messageInvalidated(sessionID: "root")))
    #expect(store.state.refresh?.racedEventsIncomplete == true)
    #expect(store.state.refresh?.followup == .invalidation)

    await gate.open()
    await settle(store)
    #expect(await reads.count("reads") >= 2)
    #expect(store.state.activeTranscript?.items.map(\.id) == ["u1", "m-text-0", "m-tool-t1"])
    guard case .assistantMarkdown(_, let text, _)? =
      store.state.activeTranscript?.items.first(where: { $0.id == "m-text-0" })
    else {
      Issue.record("expected authoritative markdown")
      return
    }
    #expect(text == "authoritative")
    guard case .tool(_, let call)? =
      store.state.activeTranscript?.items.first(where: { $0.id == "m-tool-t1" })
    else {
      Issue.record("expected authoritative tool")
      return
    }
    #expect(call.status == .completed)
    #expect(call.output == ["final"])
    #expect(!store.state.activeTranscript!.items.contains { item in
      if case .assistantMarkdown(_, let text, _) = item { return text.contains("t0") }
      return false
    })
  }

  @Test("a durable boundary after raced overflow still schedules rehydration")
  func racedOverflowKeepsDurableBoundary() async {
    let gate = Gate()
    let reads = CallCounter()
    let store = makeStore(
      state(),
      client: client(
        getSession: { _, _ in self.root() },
        transcript: { _, _, _ in
          let count = await reads.count("reads")
          await reads.increment("reads")
          if count == 0 {
            await gate.wait()
            return TranscriptPage(items: [])
          }
          return TranscriptPage(
            items: [.assistantMarkdown(id: "m-text-0", text: "settled", inProgress: false)]
          )
        }
      )
    )
    await store.send(.task)
    #expect(await waitUntil { store.state.refresh != nil })
    #expect(await waitUntil { await reads.count("reads") == 1 })
    for index in 0..<513 {
      await store.send(
        .serverEvent(
          .contentBatch(
            sessionID: "root",
            events: [.textDelta(messageID: "m", ordinal: 0, delta: "\(index)", accumulatedText: nil)]
          )
        )
      )
    }
    await store.send(
      .serverEvent(
        .contentBatch(
          sessionID: "root",
          events: [.textEnded(messageID: "m", ordinal: 0, text: "settled")]
        )
      )
    )
    #expect(store.state.refresh?.racedEventsIncomplete == true)
    #expect(store.state.refresh?.followup == .settlement(messageID: "m"))
    await gate.open()
    await settle(store)
    #expect(await reads.count("reads") >= 2)
    guard case .assistantMarkdown(_, let text, _)? =
      store.state.activeTranscript?.items.first(where: { $0.id == "m-text-0" })
    else {
      Issue.record("expected settled row")
      return
    }
    #expect(text == "settled")
  }

  @Test("six hundred streamed tokens retain their tail through settlement")
  func streamTailGate() async {
    let reads = CallCounter()
    let durableText = (0..<600).map { "tok\($0) " }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    let store = makeStore(
      state(),
      client: client(
        getSession: { _, _ in self.root() },
        transcript: { _, _, _ in
          let count = await reads.count("reads")
          await reads.increment("reads")
          guard count > 0 else { return TranscriptPage(items: []) }
          return TranscriptPage(
            items: [
              .assistantMarkdown(id: "m-text-0", text: durableText, inProgress: false)
            ]
          )
        }
      )
    )
    await store.send(.task)
    await settle(store)
    var expected = ""
    var events: [LiveContentEvent] = [.textStarted(messageID: "m", ordinal: 0)]
    for index in 0..<600 {
      let token = "tok\(index) "
      expected += token
      events.append(.textDelta(messageID: "m", ordinal: 0, delta: token, accumulatedText: nil))
    }
    await store.send(.serverEvent(.contentBatch(sessionID: "root", events: events)))
    let item = store.state.activeTranscript?.items.first(where: { $0.id == "m-text-0" })
    guard case .assistantMarkdown(_, let text, _)? = item else {
      Issue.record("expected a streaming row")
      return
    }
    #expect(text == expected)
    #expect(text.hasSuffix("tok599 "))

    await store.send(.serverEvent(.contentBatch(sessionID: "root", events: [
      .textEnded(messageID: "m", ordinal: 0, text: expected),
    ])))
    await settle(store)
    guard case .assistantMarkdown(_, let settled, _)? = store.state.activeTranscript?.items.first(where: { $0.id == "m-text-0" }) else {
      Issue.record("expected the settled row")
      return
    }
    #expect(settled == expected.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  @Test("a thousand rows keep one entry identity each")
  func thousandRows() async {
    let items = (0..<1_000).map { index -> TranscriptItem in
      index.isMultiple(of: 2) ? user("u\(index)") : reply("a\(index)")
    }
    let store = makeStore(
      state(),
      client: client(
        getSession: { _, _ in self.root() },
        transcript: { _, _, _ in TranscriptPage(items: items) }
      )
    )
    await store.send(.task)
    await settle(store)
    let entries = store.state.activeTranscript?.entries ?? []
    #expect(entries.count == 1_500)
    #expect(Set(entries.map(\.id)).count == entries.count)
  }
}

private actor Counter {
  private var remaining: Int
  init(limit: Int) { remaining = limit }
  func take() -> Bool {
    guard remaining > 0 else { return false }
    remaining -= 1
    return true
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
    let pending = waiters
    waiters.removeAll()
    for continuation in pending { continuation.resume() }
  }
}

private actor CallCounter {
  private var names: [String] = []

  func increment(_ name: String) { names.append(name) }
  func count(_ name: String) -> Int { names.filter { $0 == name }.count }
}
