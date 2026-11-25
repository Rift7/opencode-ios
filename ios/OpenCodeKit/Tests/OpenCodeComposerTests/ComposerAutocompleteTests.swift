import Foundation
import OpenCodeComposer
import OpenCodeServer
import Testing

@Suite("Composer autocomplete")
struct ComposerAutocompleteTests {
  private let skill = ServerSkill(id: "review", name: "review", description: "Review a change")
  private let agent = ServerAgent(id: "build", name: "build", description: "Build things", mode: "subagent")
  private let primary = ServerAgent(id: "plan", name: "plan", mode: "primary")

  private func chip(
    _ token: String,
    at start: Int,
    kind: ComposerMentionChip.Kind = .skill,
    value: String = "review",
    title: String = "review",
    suggestion: String = "skill:review",
    occurrence: String = UUID().uuidString.lowercased()
  ) -> ComposerMentionChip {
    ComposerMentionChip(
      id: suggestion,
      kind: kind,
      value: value,
      token: token,
      title: title,
      occurrenceID: occurrence,
      start: start,
      end: start + token.utf16.count
    )
  }

  @Test("a mention is detected at a word boundary and a command only at the start")
  func triggerDetection() {
    let mention = ComposerAutocompleteTrigger.detect(text: "Please @rev")
    #expect(mention?.mode == .mention)
    #expect(mention?.query == "rev")
    #expect(mention?.start == 7)

    #expect(ComposerAutocompleteTrigger.detect(text: "email@example.com") == nil)
    #expect(ComposerAutocompleteTrigger.detect(text: "not @ a trigger") == nil)

    let command = ComposerAutocompleteTrigger.detect(text: "/com")
    #expect(command?.mode == .command)
    #expect(command?.query == "com")
    #expect(ComposerAutocompleteTrigger.detect(text: "hello /com") == nil)
  }

  @Test("a caret inside a committed occurrence does not reopen the list")
  func committedChipIsNotATrigger() {
    let review = chip("@review", at: 4)
    let text = "Use @review "
    #expect(ComposerAutocompleteTrigger.detect(text: text, caret: 10, chips: [review]) == nil)
    #expect(ComposerAutocompleteTrigger.detect(text: text + "@bu", chips: [review])?.query == "bu")
  }

  @Test("rows are bounded and ignore hidden agents")
  func rows() {
    var state = ComposerAutocompleteState(
      trigger: .init(mode: .mention, query: "", start: 0, end: 1),
      skills: [skill],
      agents: [agent, primary, ServerAgent(id: "hidden", hidden: true)]
    )
    state.recompute()
    #expect(state.suggestions.count == 2)
    #expect(state.suggestions.map(\.id) == ["skill:review", "agent:build"])
    #expect(state.suggestions.first?.title == "review")
  }

  @Test("repeated selections are distinct occurrences with exact UTF-16 ranges")
  func repeatedSelections() {
    let text = "One 👋 @rev and @rev"
    let at = (text as NSString).range(of: "@rev").location
    let firstTrigger = ComposerAutocompleteTrigger.detect(text: text, caret: at + 4)!
    #expect(firstTrigger.start == at)
    let suggestion = ComposerAutocompleteSuggestion(
      id: "skill:review",
      title: "review",
      subtitle: "",
      token: "@review",
      payload: .skill(skill)
    )
    let first = ComposerMentionBuilder.apply(
      suggestion,
      trigger: firstTrigger,
      to: text,
      occurrenceID: "occurrence-1"
    )!
    #expect(first.chip.start == at)
    #expect(first.chip.end == at + "@review".utf16.count)
    #expect(first.chip.occurrenceID == "occurrence-1")

    let secondTrigger = ComposerAutocompleteTrigger.detect(text: first.text)!
    let second = ComposerMentionBuilder.apply(
      suggestion,
      trigger: secondTrigger,
      to: first.text,
      occurrenceID: "occurrence-2"
    )!
    #expect(second.chip.start == secondTrigger.start)
    #expect(second.chip.occurrenceID == "occurrence-2")
    #expect(second.chip.occurrenceID != first.chip.occurrenceID)

    let mentions = ComposerMentionBuilder.mentions(
      text: second.text,
      chips: [first.chip, second.chip]
    )
    #expect(mentions.skills.map(\.mention?.start) == [first.chip.start, secondTrigger.start])
  }

  @Test("duplicate filenames keep their own remote identities and ranges")
  func duplicateFilenames() {
    let firstURI = "file:///work/a/App.swift"
    let secondURI = "file:///work/b/App.swift"
    let text = "Use @App.swift then @App.swift now"
    let ns = text as NSString
    let firstStart = ns.range(of: "@App.swift").location
    let secondStart = ns.range(of: "@App.swift", options: [], range: NSRange(location: firstStart + 10, length: ns.length - firstStart - 10)).location
    let firstChip = chip("@App.swift", at: firstStart, kind: .file, value: firstURI, title: "App.swift", suggestion: "file:\(firstURI)")
    let secondChip = chip("@App.swift", at: secondStart, kind: .file, value: secondURI, title: "App.swift", suggestion: "file:\(secondURI)")
    let mentions = ComposerMentionBuilder.mentions(text: text, chips: [firstChip, secondChip])
    #expect(mentions.files.map(\.uri) == [firstURI, secondURI])
    #expect(mentions.files.map(\.mention?.start) == [firstStart, secondStart])
    #expect(mentions.files.map(\.mention?.end) == [firstStart + 10, secondStart + 10])
  }

  @Test("identical ordinary text is not a mention")
  func ordinaryTextDoesNotBecomeAMention() {
    let text = "The word @review appears without a chosen chip."
    #expect(
      ComposerMentionBuilder.mentions(text: text, chips: []).isEmpty
    )
    let shifted = chip("@review", at: 4)
    #expect(
      ComposerMentionBuilder.mentions(
        text: "Use @reviewed instead",
        chips: [shifted]
      ).isEmpty
    )
  }

  @Test("edits before an occurrence shift it; edits inside invalidate it")
  func editMaintenance() {
    let text = "Use @review now"
    let review = chip("@review", at: 4)
    let shifted = ComposerMentionBuilder.applyingEdit(
      range: NSRange(location: 0, length: 0),
      replacementLength: 4,
      chips: [review]
    )
    #expect(shifted.first?.start == 8)
    #expect(
      ComposerMentionBuilder.mentions(text: "1234" + text, chips: shifted).skills.first?.mention?.start
        == 8
    )

    let inside = ComposerMentionBuilder.applyingEdit(
      range: NSRange(location: 5, length: 1),
      replacementLength: 1,
      chips: [review]
    )
    #expect(inside.isEmpty)

    let deleted = ComposerMentionBuilder.applyingEdit(
      range: NSRange(location: 4, length: 7),
      replacementLength: 0,
      chips: [review]
    )
    #expect(deleted.isEmpty)

    let insertionAfter = ComposerMentionBuilder.applyingEdit(
      range: NSRange(location: 14, length: 0),
      replacementLength: 3,
      chips: [review]
    )
    #expect(insertionAfter.first?.start == 4)
    #expect(insertionAfter.first?.end == 11)
  }

  @Test("Unicode before and inside text keeps exact UTF-16 wire spans")
  func unicodeSpans() {
    let text = "👩‍💻 hello @review"
    let start = (text as NSString).range(of: "@review").location
    let review = chip("@review", at: start)
    let mentions = ComposerMentionBuilder.mentions(text: text, chips: [review])
    #expect(mentions.skills.first?.mention?.start == start)
    #expect(mentions.skills.first?.mention?.end == start + 7)
  }

  @Test("an invalid stored range contributes nothing")
  func invalidRange() {
    var review = chip("@review", at: 4)
    review.end = 99
    #expect(ComposerMentionBuilder.mentions(text: "Use @review", chips: [review]).isEmpty)
  }

  @Test("occurrences and ranges survive draft encoding and restore")
  func draftPersistence() throws {
    let text = "First @review and second @review"
    let ns = text as NSString
    let firstStart = ns.range(of: "@review").location
    let secondStart = ns.range(
      of: "@review",
      options: [],
      range: NSRange(location: firstStart + 7, length: ns.length - firstStart - 7)
    ).location
    let draft = ComposerDraft(
      text: text,
      chips: [
        chip("@review", at: firstStart, occurrence: "occurrence-1"),
        chip("@review", at: secondStart, occurrence: "occurrence-2"),
      ],
      revision: 3,
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let data = try JSONEncoder().encode(draft)
    let restored = try JSONDecoder().decode(ComposerDraft.self, from: data)
    #expect(restored.chips.map(\.occurrenceID) == ["occurrence-1", "occurrence-2"])
    let mentions = ComposerMentionBuilder.mentions(text: restored.text, chips: restored.chips)
    #expect(mentions.skills.map(\.mention?.start) == [firstStart, secondStart])
  }

  @Test("Return follows the preference, Shift always inserts, marked text passes through")
  func returnKeyDecision() {
    #expect(
      ComposerReturnKey.action(replacement: "\n", markedText: false, shift: false, returnSends: true)
        == .send
    )
    #expect(
      ComposerReturnKey.action(replacement: "\n", markedText: false, shift: false, returnSends: false)
        == .insertNewline
    )
    #expect(
      ComposerReturnKey.action(replacement: "\n", markedText: false, shift: true, returnSends: true)
        == .insertNewline
    )
    #expect(
      ComposerReturnKey.action(replacement: "\n", markedText: true, shift: false, returnSends: true)
        == .passThrough
    )
    #expect(
      ComposerReturnKey.action(replacement: "x", markedText: false, shift: false, returnSends: true)
        == .passThrough
    )
  }
}
