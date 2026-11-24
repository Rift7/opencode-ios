import Foundation
import OpenCodeComposer
import OpenCodeServer
import Testing

@Suite("Composer autocomplete")
struct ComposerAutocompleteTests {
  private let skill = ServerSkill(id: "review", name: "review", description: "Review a change")
  private let agent = ServerAgent(id: "build", name: "build", description: "Build things", mode: "subagent")
  private let primary = ServerAgent(id: "plan", name: "plan", mode: "primary")

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

  @Test("a caret inside a committed token does not reopen the list")
  func committedChipIsNotATrigger() {
    let chip = ComposerMentionChip(
      id: "skill:review",
      kind: .skill,
      value: "review",
      token: "@review",
      title: "review"
    )
    let text = "Use @review "
    #expect(ComposerAutocompleteTrigger.detect(text: text, caret: 10, chips: [chip]) == nil)
    #expect(ComposerAutocompleteTrigger.detect(text: text + "@bu", chips: [chip])?.query == "bu")
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

  @Test("a suggestion replaces the trigger by UTF-16 offsets")
  func appliesByUTF16Offset() {
    let text = "Hi 👋 @rev"
    let trigger = ComposerAutocompleteTrigger.detect(text: text)
    #expect(trigger != nil)
    let suggestion = ComposerAutocompleteSuggestion(
      id: "skill:review",
      title: "review",
      subtitle: "",
      token: "@review",
      payload: .skill(skill)
    )
    let applied = ComposerMentionBuilder.apply(suggestion, trigger: trigger!, to: text)
    #expect(applied?.text == "Hi 👋 @review ")
    #expect(applied?.chip.kind == .skill)
    #expect(applied?.chip.value == "review")
  }

  @Test("mentions carry exact wire ranges and a file URI, never a display label alone")
  func mentionWireShape() {
    let file = ServerFileSuggestion(path: "/work/box/Sources/App.swift")
    let chip = ComposerMentionChip(
      id: "file:/work/box/Sources/App.swift",
      kind: .file,
      value: file.uri,
      token: "@App.swift",
      title: "App.swift"
    )
    let text = "Look at @App.swift and @review"
    let skillChip = ComposerMentionChip(
      id: "skill:review",
      kind: .skill,
      value: "review",
      token: "@review",
      title: "review"
    )
    let mentions = ComposerMentionBuilder.mentions(text: text, chips: [chip, skillChip])
    #expect(mentions.files.count == 1)
    #expect(mentions.files[0].uri.hasPrefix("file:///work/box/"))
    #expect(mentions.files[0].name == "App.swift")
    #expect(mentions.files[0].mention?.start == 8)
    #expect(mentions.files[0].mention?.end == 18)
    #expect(mentions.skills.first?.mention?.text == "@review")
  }

  @Test("an edited token contributes no stale mention")
  func editedTokenDropsMention() {
    let chip = ComposerMentionChip(
      id: "skill:review",
      kind: .skill,
      value: "review",
      token: "@review",
      title: "review"
    )
    let mentions = ComposerMentionBuilder.mentions(text: "Use @reviewed", chips: [chip])
    #expect(mentions.isEmpty)
  }

  @Test("the prompt carries agents, skills and file mentions in the audited fields")
  func promptShape() {
    let chip = ComposerMentionChip(
      id: "skill:review",
      kind: .skill,
      value: "review",
      token: "@review",
      title: "review"
    )
    let send = ComposerSend(
      target: .session(id: "s1"),
      messageID: "m1",
      text: "Use @review",
      quotes: [],
      delivery: .steer,
      revision: 1,
      chips: [chip],
      model: ModelRef(id: "model", providerID: "provider", variant: "high"),
      agent: "build"
    )
    let body = send.prompt()
    #expect(body.agents == nil)
    #expect(body.skills?.first?.id == "review")
    #expect(body.skills?.first?.mention?.start == 4)
    #expect(send.model?.variant == "high")
    #expect(send.agent == "build")
  }
}
