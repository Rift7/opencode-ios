import Foundation
import OpenCodeServer
import OpenCodeTranscript
import Testing

@Suite("Transcript grouping and projection")
struct TranscriptGroupingTests {
  private func user(_ id: String, _ text: String = "prompt") -> TranscriptItem {
    .userText(id: id, text: text, source: nil, quotes: [])
  }

  private func reply(_ id: String, _ text: String = "reply") -> TranscriptItem {
    .assistantMarkdown(id: id, text: text, inProgress: false)
  }

  private func tool(_ id: String, _ name: String = "read", status: TranscriptToolCall.Status = .completed)
    -> TranscriptItem
  {
    .tool(
      id: id,
      call: TranscriptToolCall(callID: id, name: name, status: status, input: .object(["path": .string("a")]))
    )
  }

  @Test("groups consecutive tools and notices, and ends each finished reply")
  func grouping() {
    let items = [
      user("u1"),
      reply("a1"),
      tool("t1"),
      tool("t2"),
      .notice(
        id: "n1",
        text: "done",
        isError: false,
        kind: TranscriptNoticeKind(source: .shell, outcome: .finished),
        agent: nil
      ),
      user("u2"),
      reply("a2"),
    ]
    let entries = TranscriptGrouping.build(items: items, isRunning: false)
    #expect(entries.map(\.id) == [
      "user-u1",
      "a1",
      "group-t1",
      "reply-end-a1",
      "user-u2",
      "a2",
      "reply-end-a2",
    ])
    #expect(entries[0].userMessageID == "u1")
    #expect(entries[2].toolCalls.map(\.name) == ["read", "read"])
    #expect(entries.last?.itemIDs == [])
  }

  @Test("the last reply has no Copy row until the run stops")
  func replyEndWaits() {
    let entries = TranscriptGrouping.build(items: [user("u1"), reply("a1")], isRunning: true)
    #expect(entries.map(\.id) == ["user-u1", "a1"])
    #expect(!entries.contains { if case .replyEnd = $0 { true } else { false } })
    let settled = TranscriptGrouping.build(items: [user("u1"), reply("a1")], isRunning: false)
    #expect(settled.last.map(\.id) == "reply-end-a1")
    if case .replyEnd(_, let texts)? = settled.last {
      #expect(texts == ["reply"])
    }
  }

  @Test("a pending question is the dock's while it runs, and stays as history once answered")
  func pendingQuestion() {
    let running = TranscriptToolCall(callID: "q", name: "question", status: .running)
    let answered = TranscriptToolCall(callID: "q", name: "question", status: .completed)
    let hidden = TranscriptGrouping.build(items: [.tool(id: "q1", call: running)])
    #expect(hidden.isEmpty)
    let shown = TranscriptGrouping.build(items: [.tool(id: "q1", call: answered)])
    #expect(shown.map(\.id) == ["group-q1"])
  }

  @Test("a session-start model switch is not shown as a switch")
  func startModel() {
    let start = TranscriptItem.modelSwitch(
      id: "m1",
      model: TranscriptModelRef(id: "a", providerID: "p"),
      previous: nil,
      name: "A"
    )
    let later = TranscriptItem.modelSwitch(
      id: "m2",
      model: TranscriptModelRef(id: "b", providerID: "p"),
      previous: TranscriptModelRef(id: "a", providerID: "p"),
      name: "B"
    )
    let entries = TranscriptGrouping.build(items: [start, later])
    #expect(entries.map(\.id) == ["m2"])
  }

  @Test("a repeated before-reply run error is hidden once the turn already shows one")
  func beforeReplyDuplicate() {
    let first = TranscriptItem.runError(
      id: "idle-1",
      error: TranscriptRunError(type: "provider.auth", message: "no", beforeReply: true)
    )
    let second = TranscriptItem.runError(
      id: "idle-2",
      error: TranscriptRunError(type: "provider.auth", message: "no", beforeReply: true)
    )
    let entries = TranscriptGrouping.build(items: [user("u1"), first, second])
    #expect(entries.filter { if case .single(.runError) = $0 { true } else { false } }.count == 1)
  }

  @Test("a window does not split a tool group")
  func entryStart() {
    let items = [user("u1"), tool("t1"), tool("t2"), reply("a1")]
    #expect(TranscriptGrouping.entryStart(2, items: items) == 1)
    #expect(TranscriptGrouping.entryStart(3, items: items) == 3)
  }

  @Test("a thousand entries keep the same stable identities across rebuilds")
  func thousandRows() {
    let items = (0..<1_000).map { index in
      index.isMultiple(of: 2)
        ? user("u\(index)")
        : reply("a\(index)", "Reply \(index)")
    }
    let first = TranscriptGrouping.build(items: items, isRunning: false)
    let second = TranscriptGrouping.build(items: items, isRunning: false)
    #expect(first.count == 1_500)
    #expect(first.map(\.id) == second.map(\.id))
    #expect(Set(first.map(\.id)).count == first.count)
    #expect(first.last?.id == "reply-end-a999")
  }

  @Test("a newest window replaces its range and keeps older loaded history")
  func mergeNewest() {
    let existing = [
      user("old-user"),
      reply("old-reply"),
      user("u2"),
      reply("a2", "old"),
    ]
    let fetched = [
      reply("a2", "new"),
      user("u3"),
      reply("a3"),
    ]
    let merged = TranscriptProjection.mergeNewest(fetched: fetched, existing: existing)
    #expect(merged.map(\.id) == ["old-user", "old-reply", "u2", "a2", "u3", "a3"])
    if case .assistantMarkdown(_, let text, _) = merged[3] { #expect(text == "new") }
  }

  @Test("a complete page replaces the whole transcript")
  func completePage() {
    let existing = [user("old"), reply("old-reply")]
    let merged = TranscriptProjection.mergeNewest(
      fetched: [user("new")],
      existing: existing,
      complete: true
    )
    #expect(merged.map(\.id) == ["new"])
  }

  @Test("an unpersisted streaming part survives a snapshot and keeps its place")
  func inProgressSurvives() {
    let existing: [TranscriptItem] = [
      user("u1"),
      .assistantMarkdown(id: "a1-text-0", text: "partial", inProgress: true),
      user("u2"),
    ]
    let fetched: [TranscriptItem] = [user("u2")]
    let merged = TranscriptProjection.mergeNewest(fetched: fetched, existing: existing)
    #expect(merged.map(\.id) == ["u1", "a1-text-0", "u2"])
  }

  @Test("an older page splices before its earliest overlap and drops duplicate rows")
  func mergeOlderOverlap() {
    let existing = [user("u3"), reply("a3"), user("u4")]
    let page = [user("u1"), reply("a1"), user("u3")]
    let merged = TranscriptProjection.mergeOlder(
      page: page,
      existing: existing,
      reachedLoadedItems: true
    )
    #expect(merged?.map(\.id) == ["u1", "a1", "u3", "a3", "u4"])
  }

  @Test("a disjoint older page keeps seeking until it finds the loaded rows")
  func mergeOlderSeeks() {
    let existing = [user("u3")]
    #expect(
      TranscriptProjection.mergeOlder(
        page: [user("u1"), reply("a1")],
        existing: existing,
        reachedLoadedItems: false
      ) == nil
    )
    let firstPage = TranscriptProjection.mergeOlder(
      page: [user("u1"), reply("a1")],
      existing: [],
      reachedLoadedItems: false
    )
    #expect(firstPage?.map(\.id) == ["u1", "a1"])
  }

  @Test("six hundred streamed tokens keep their complete tail")
  func streamedTail() {
    var items: [TranscriptItem] = []
    var expected = ""
    var events: [LiveContentEvent] = [.textStarted(messageID: "m1", ordinal: 0)]
    for index in 0..<600 {
      let token = "token-\(index) "
      expected += token
      events.append(
        .textDelta(messageID: "m1", ordinal: 0, delta: token, accumulatedText: nil)
      )
    }
    events.append(.textEnded(messageID: "m1", ordinal: 0, text: expected))
    TranscriptProjection.apply(events: events, to: &items)
    #expect(items.count == 1)
    guard case .assistantMarkdown(let id, let text, let inProgress) = items[0] else {
      Issue.record("expected one markdown row")
      return
    }
    #expect(id == "m1-text-0")
    #expect(text == expected.trimmingCharacters(in: .whitespacesAndNewlines))
    #expect(text.hasSuffix("token-599"))
    #expect(!inProgress)
  }

  @Test("a delta that arrives before its start still creates the part")
  func deltaFirst() {
    var items: [TranscriptItem] = []
    TranscriptProjection.apply(
      events: [.textDelta(messageID: "m", ordinal: 1, delta: "hi", accumulatedText: nil)],
      to: &items
    )
    #expect(items.map(\.id) == ["m-text-1"])
  }

  @Test("tool lifecycle events upsert one row by the server's part identity")
  func toolLifecycle() {
    var items: [TranscriptItem] = [
      user("u1"),
      .tool(
        id: "m-tool-t1",
        call: TranscriptToolCall(callID: "t1", messageID: "m", name: "read", status: .streaming)
      ),
    ]
    TranscriptProjection.apply(
      events: [
        .toolInputStarted(messageID: "m", toolID: "t1", name: "read"),
        .toolInputDelta(messageID: "m", toolID: "t1", delta: "{\"path\""),
        .toolCalled(messageID: "m", toolID: "t1", input: .object(["path": .string("a")])),
        .toolSucceeded(messageID: "m", toolID: "t1", output: ["ok"], metadata: [:]),
      ],
      to: &items
    )
    #expect(items.count == 2)
    guard case .tool(let id, let call) = items[1] else {
      Issue.record("expected tool")
      return
    }
    #expect(id == "m-tool-t1")
    #expect(call.status == .completed)
    #expect(call.inputPath == "a")
    #expect(call.output == ["ok"])
  }

  @Test("a stale delta or tool event cannot regress a durable snapshot")
  func replayIsMonotonic() {
    var items: [TranscriptItem] = [
      .assistantMarkdown(id: "m-text-0", text: "settled", inProgress: false),
      .tool(
        id: "m-tool-t",
        call: TranscriptToolCall(
          callID: "t",
          messageID: "m",
          name: "read",
          status: .completed,
          output: ["done"]
        )
      ),
    ]
    TranscriptProjection.apply(
      events: [
        .textStarted(messageID: "m", ordinal: 0),
        .textDelta(messageID: "m", ordinal: 0, delta: " stale", accumulatedText: nil),
        .textEnded(messageID: "m", ordinal: 0, text: "stale"),
        .toolInputStarted(messageID: "m", toolID: "t", name: "read"),
        .toolInputDelta(messageID: "m", toolID: "t", delta: "stale"),
        .toolCalled(messageID: "m", toolID: "t", input: .object(["path": .string("x")])),
        .toolProgress(messageID: "m", toolID: "t", metadata: [:]),
        .toolSucceeded(messageID: "m", toolID: "t", output: ["stale"], metadata: [:]),
      ],
      to: &items
    )
    guard case .assistantMarkdown(_, let text, let inProgress) = items[0] else {
      Issue.record("expected markdown")
      return
    }
    #expect(text == "settled")
    #expect(!inProgress)
    guard case .tool(_, let call) = items[1] else {
      Issue.record("expected tool")
      return
    }
    #expect(call.status == .completed)
    #expect(call.output == ["done"])
    #expect(call.input == .null)
  }

  @Test("an ended empty text part leaves no row, and reasoning never makes one")
  func emptyAndReasoning() {
    var items: [TranscriptItem] = []
    TranscriptProjection.apply(
      events: [
        .reasoningStarted(messageID: "m", ordinal: 0),
        .reasoningDelta(messageID: "m", ordinal: 0),
        .reasoningEnded(messageID: "m", ordinal: 0),
        .textStarted(messageID: "m", ordinal: 1),
        .textEnded(messageID: "m", ordinal: 1, text: "   "),
      ],
      to: &items
    )
    #expect(items.isEmpty)
  }
}

@Suite("Markdown")
struct MarkdownTests {
  @Test("headings, lists, tasks, quotes, code, tables, rules and math parse")
  func blocks() {
    let source = """
      # Title

      A paragraph with **bold** and `code`.

      - one
      - [x] done
      - [ ] open

      1. first
      2. second

      > quoted
      > more

      ```swift
      let x = 1
      ```

      | A | B |
      | --- | --- |
      | 1 | 2 |

      ---

      $$
      x^2
      $$
      """
    let blocks = MarkdownParser.parse(source)
    #expect(blocks.contains(.heading(level: 1, text: "Title")))
    #expect(blocks.contains(.paragraph("A paragraph with **bold** and `code`.")))
    #expect(
      blocks.contains(
        .list(
          ordered: false,
          items: [
            MarkdownListItem(text: "one"),
            MarkdownListItem(text: "done", checked: true),
            MarkdownListItem(text: "open", checked: false),
          ]
        )
      )
    )
    #expect(blocks.contains(.list(ordered: true, items: [
      MarkdownListItem(text: "first"),
      MarkdownListItem(text: "second"),
    ])))
    #expect(blocks.contains(.quote("quoted\nmore")))
    #expect(blocks.contains(.code(language: "swift", text: "let x = 1")))
    #expect(blocks.contains(.table(header: ["A", "B"], rows: [["1", "2"]])))
    #expect(blocks.contains(.rule))
    #expect(blocks.contains(.math("x^2")))
  }

  @Test("an unclosed streaming fence keeps its text")
  func unclosedFence() {
    let blocks = MarkdownParser.parse("```swift\nlet x = 1")
    #expect(blocks == [.code(language: "swift", text: "let x = 1")])
  }

  @Test("malformed content falls back to text instead of disappearing")
  func malformed() {
    #expect(MarkdownParser.parse("| one |\nnot a divider | two |").count >= 1)
    let inline = MarkdownParser.inline("**unclosed")
    #expect(!String(inline.characters).isEmpty)
    #expect(MarkdownParser.parse("plain <b>tags</b>").contains(.paragraph("plain <b>tags</b>")))
  }

  @Test("a remote image is a link, never a fetch")
  func image() {
    #expect(
      MarkdownParser.parse("![diagram](https://example.com/a.png)")
        == [.image(alt: "diagram", url: "https://example.com/a.png")]
    )
  }

  @Test("copy text preserves the Markdown structures")
  func copyText() {
    let blocks: [MarkdownBlock] = [
      .heading(level: 2, text: "Title"),
      .list(ordered: false, items: [MarkdownListItem(text: "done", checked: true)]),
      .code(language: "swift", text: "let x = 1"),
      .table(header: ["A"], rows: [["1"]]),
    ]
    let text = MarkdownParser.markdown(from: blocks)
    #expect(text.contains("## Title"))
    #expect(text.contains("- [x] done"))
    #expect(text.contains("```swift\nlet x = 1\n```"))
    #expect(text.contains("| A |"))
  }

  @MainActor
  @Test("only the current content revision can publish Markdown blocks")
  func latestParseWins() async {
    let parser = ControlledMarkdownParser()
    let presenter = MarkdownBlockPresenter(
      cache: MarkdownBlockCache(),
      parser: MarkdownParserClient { await parser.parse($0) }
    )
    presenter.load(key: "A", text: "A")
    await parser.waitUntilStarted("A")
    presenter.load(key: "B", text: "B")
    await parser.waitUntilStarted("B")
    await parser.complete("B", [.paragraph("B")])
    #expect(await eventually { presenter.blocks == [.paragraph("B")] })
    await parser.complete("A", [.paragraph("A")])
    #expect(await eventually { presenter.blocks == [.paragraph("B")] })
  }

  @MainActor
  @Test("changing content clears stale blocks until the new parse lands")
  func staleBlocksClear() async {
    let parser = ControlledMarkdownParser()
    let presenter = MarkdownBlockPresenter(
      cache: MarkdownBlockCache(),
      parser: MarkdownParserClient { await parser.parse($0) }
    )
    presenter.load(key: "A", text: "A")
    await parser.waitUntilStarted("A")
    await parser.complete("A", [.paragraph("A")])
    #expect(await eventually { presenter.blocks == [.paragraph("A")] })

    presenter.load(key: "B", text: "B")
    await parser.waitUntilStarted("B")
    #expect(presenter.blocks == nil)
    await parser.complete("A", [.paragraph("late A")])
    await parser.complete("B", [.paragraph("B")])
    #expect(await eventually { presenter.blocks == [.paragraph("B")] })
  }

  @MainActor
  @Test("a disappeared or replaced row cannot publish a late parse")
  func disappearanceFencesPublication() async {
    let parser = ControlledMarkdownParser()
    let presenter = MarkdownBlockPresenter(
      cache: MarkdownBlockCache(),
      parser: MarkdownParserClient { await parser.parse($0) }
    )
    presenter.load(key: "A", text: "A")
    await parser.waitUntilStarted("A")
    presenter.clear()
    await parser.complete("A", [.paragraph("A")])
    try? await Task.sleep(for: .milliseconds(50))
    #expect(presenter.blocks == nil)
    #expect(presenter.displayedKey == nil)
  }

  @Test("the block cache is bounded and clears")
  func cacheBounds() async {
    let cache = MarkdownBlockCache(maximumEntries: 2, maximumCharacters: 1_000)
    _ = await cache.blocks(for: "a", text: String(repeating: "a", count: 400))
    _ = await cache.blocks(for: "b", text: String(repeating: "b", count: 400))
    _ = await cache.blocks(for: "c", text: String(repeating: "c", count: 400))
    #expect(await cache.count == 2)
    await cache.clear()
    #expect(await cache.count == 0)
    #expect(await cache.characterCount == 0)
  }
}

private actor ControlledMarkdownParser {
  private var started: Set<String> = []
  private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  private var parseWaiters: [String: [CheckedContinuation<[MarkdownBlock], Never>]] = [:]

  func parse(_ text: String) async -> [MarkdownBlock] {
    await withCheckedContinuation { continuation in
      parseWaiters[text, default: []].append(continuation)
      started.insert(text)
      for waiter in startWaiters[text] ?? [] { waiter.resume() }
      startWaiters[text] = nil
    }
  }

  func waitUntilStarted(_ text: String) async {
    if started.contains(text) { return }
    await withCheckedContinuation { continuation in
      startWaiters[text, default: []].append(continuation)
    }
  }

  func complete(_ text: String, _ blocks: [MarkdownBlock]) {
    for waiter in parseWaiters[text] ?? [] { waiter.resume(returning: blocks) }
    parseWaiters[text] = nil
  }
}

@MainActor
private func eventually(
  timeout: Duration = .seconds(1),
  _ condition: () -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}
