import Foundation
import OpenCodeServer

/// One semantic mention or command choice kept with the draft. `token` is the visible text; the
/// wire mention range is derived from it at send time, so an edited token contributes nothing.
public struct ComposerMentionChip: Codable, Identifiable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case skill
    case agent
    case file
    case command
  }

  public var id: String
  public var kind: Kind
  /// The skill ID, agent ID, remote file URI, or command name.
  public var value: String
  public var token: String
  public var title: String

  public init(id: String, kind: Kind, value: String, token: String, title: String) {
    self.id = id
    self.kind = kind
    self.value = value
    self.token = token
    self.title = title
  }

  public var isMention: Bool { kind != .command }
}

public struct ComposerAutocompleteTrigger: Equatable, Sendable {
  public enum Mode: String, Equatable, Sendable {
    case mention
    case command
  }

  public var mode: Mode
  public var query: String
  /// UTF-16 offsets in the draft.
  public var start: Int
  public var end: Int

  public init(mode: Mode, query: String, start: Int, end: Int) {
    self.mode = mode
    self.query = query
    self.start = start
    self.end = end
  }

  public var key: String { "\(mode.rawValue):\(start)" }

  /// Detects an active `@` at a word boundary or `/` at the message start, ending at `caret`.
  /// A caret inside an existing chip token is not a new trigger.
  public static func detect(
    text: String,
    caret: Int? = nil,
    chips: [ComposerMentionChip] = []
  ) -> ComposerAutocompleteTrigger? {
    let units = Array(text.utf16)
    let limit = min(max(0, caret ?? units.count), units.count)
    guard limit > 0 else { return nil }

    for range in resolvedRanges(text: text, chips: chips) where range.end == limit
      || (range.start < limit && limit <= range.end)
    {
      return nil
    }

    // A `/` command must start the message after whitespace.
    var commandStart = 0
    while commandStart < limit, isWhitespace(units[commandStart]) { commandStart += 1 }
    if commandStart < limit, units[commandStart] == 47 {
      let query = String(decoding: units[(commandStart + 1)..<limit], as: UTF16.self)
      if !query.contains(where: { isWhitespace($0.utf16.first ?? 0) }) {
        return ComposerAutocompleteTrigger(
          mode: .command,
          query: query,
          start: commandStart,
          end: limit
        )
      }
    }

    var start = limit - 1
    while start >= 0 {
      let unit = units[start]
      if unit == 64 {
        let before = start == 0 ? 32 : units[start - 1]
        guard isWhitespace(before) || start == 0 else { return nil }
        let query = String(decoding: units[(start + 1)..<limit], as: UTF16.self)
        guard !query.contains("@") else { return nil }
        // A mention query may hold inner spaces once a session title is being narrowed.
        let words = query.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count <= 8 else { return nil }
        return ComposerAutocompleteTrigger(
          mode: .mention,
          query: query,
          start: start,
          end: limit
        )
      }
      if isWhitespace(unit) {
        if unit == 10 { return nil }
        let previous = start - 1
        if previous >= 0, units[previous] == 64 {
          start = previous
          continue
        }
        return nil
      }
      start -= 1
    }
    return nil
  }

  private static func isWhitespace(_ unit: UInt16) -> Bool {
    guard let scalar = UnicodeScalar(unit) else { return false }
    return CharacterSet.whitespacesAndNewlines.contains(scalar)
  }
}

public struct ComposerAutocompleteSuggestion: Identifiable, Equatable, Sendable {
  public enum Payload: Equatable, Sendable {
    case skill(ServerSkill)
    case agent(ServerAgent)
    case file(ServerFileSuggestion)
    case command(ServerCommand)
  }

  public var id: String
  public var title: String
  public var subtitle: String
  public var token: String
  public var payload: Payload

  public init(id: String, title: String, subtitle: String, token: String, payload: Payload) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.token = token
    self.payload = payload
  }

  public var chipKind: ComposerMentionChip.Kind {
    switch payload {
    case .skill: .skill
    case .agent: .agent
    case .file: .file
    case .command: .command
    }
  }

  public var chipValue: String {
    switch payload {
    case .skill(let skill): skill.id
    case .agent(let agent): agent.id
    case .file(let file): file.uri
    case .command(let command): command.name
    }
  }

  public var chip: ComposerMentionChip {
    ComposerMentionChip(
      id: id,
      kind: chipKind,
      value: chipValue,
      token: token,
      title: title
    )
  }

  /// `file://` plus a percent-encoded absolute path. Remote paths are never read locally.
  public static func fileURI(_ path: String) -> String {
    let normalized: String
    if path.utf8.count > 2, path[path.index(path.startIndex, offsetBy: 1)] == ":" {
      normalized = "/" + path.replacingOccurrences(of: "\\", with: "/")
    } else if path.hasPrefix("/") {
      normalized = path
    } else {
      normalized = "/" + path
    }
    let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))
    return "file://" + (normalized.addingPercentEncoding(withAllowedCharacters: allowed) ?? normalized)
  }
}

public struct ComposerAutocompleteState: Equatable, Sendable {
  public static let maximumRows = 8

  public var trigger: ComposerAutocompleteTrigger?
  public var suggestions: [ComposerAutocompleteSuggestion]
  public var selectedID: String?
  public var skills: [ServerSkill]
  public var agents: [ServerAgent]
  public var commands: [ServerCommand]
  public var files: [ServerFileSuggestion]
  public var loadedDirectory: String?
  public var isLoadingCatalog: Bool
  public var fileGeneration: Int
  public var fileQuery: String?
  public var isLoadingFiles: Bool
  public var problem: ComposerAutocompleteProblem?
  public var dismissedKey: String?

  public init(
    trigger: ComposerAutocompleteTrigger? = nil,
    suggestions: [ComposerAutocompleteSuggestion] = [],
    selectedID: String? = nil,
    skills: [ServerSkill] = [],
    agents: [ServerAgent] = [],
    commands: [ServerCommand] = [],
    files: [ServerFileSuggestion] = [],
    loadedDirectory: String? = nil,
    isLoadingCatalog: Bool = false,
    fileGeneration: Int = 0,
    fileQuery: String? = nil,
    isLoadingFiles: Bool = false,
    problem: ComposerAutocompleteProblem? = nil,
    dismissedKey: String? = nil
  ) {
    self.trigger = trigger
    self.suggestions = suggestions
    self.selectedID = selectedID
    self.skills = skills
    self.agents = agents
    self.commands = commands
    self.files = files
    self.loadedDirectory = loadedDirectory
    self.isLoadingCatalog = isLoadingCatalog
    self.fileGeneration = fileGeneration
    self.fileQuery = fileQuery
    self.isLoadingFiles = isLoadingFiles
    self.problem = problem
    self.dismissedKey = dismissedKey
  }

  public var isOpen: Bool { trigger != nil && !suggestions.isEmpty }

  public mutating func close() {
    trigger = nil
    suggestions = []
    selectedID = nil
    files = []
    fileQuery = nil
    isLoadingFiles = false
  }

  public mutating func recompute() {
    guard let trigger else {
      suggestions = []
      selectedID = nil
      return
    }
    let pool: [ComposerAutocompleteSuggestion]
    switch trigger.mode {
    case .command:
      pool = commands.map(Self.command)
    case .mention:
      pool = skills.map(Self.skill)
        + agents.filter { !$0.hidden && $0.mode != "primary" }.map(Self.agent)
        + files.map(Self.file)
    }
    let filtered = trigger.query.isEmpty ? Array(pool.prefix(Self.maximumRows)) : Self.fuzzy(pool, query: trigger.query)
    suggestions = Array(filtered.prefix(Self.maximumRows))
    if let selectedID, suggestions.contains(where: { $0.id == selectedID }) {
      return
    }
    selectedID = suggestions.first?.id
  }

  public mutating func move(by delta: Int) {
    guard !suggestions.isEmpty else { return }
    let current = suggestions.firstIndex { $0.id == selectedID } ?? 0
    let next = min(max(0, current + delta), suggestions.count - 1)
    selectedID = suggestions[next].id
  }

  public func selected() -> ComposerAutocompleteSuggestion? {
    guard let selectedID else { return suggestions.first }
    return suggestions.first { $0.id == selectedID }
  }

  private static func skill(_ skill: ServerSkill) -> ComposerAutocompleteSuggestion {
    ComposerAutocompleteSuggestion(
      id: "skill:\(skill.id)",
      title: skill.name,
      subtitle: skill.description ?? "Skill",
      token: "@\(skill.name)",
      payload: .skill(skill)
    )
  }

  private static func agent(_ agent: ServerAgent) -> ComposerAutocompleteSuggestion {
    ComposerAutocompleteSuggestion(
      id: "agent:\(agent.id)",
      title: agent.displayName,
      subtitle: agent.description ?? "Subagent",
      token: "@\(agent.id)",
      payload: .agent(agent)
    )
  }

  private static func file(_ file: ServerFileSuggestion) -> ComposerAutocompleteSuggestion {
    ComposerAutocompleteSuggestion(
      id: "file:\(file.path)",
      title: file.name,
      subtitle: file.relativePath,
      token: "@\(file.name)",
      payload: .file(file)
    )
  }

  private static func command(_ command: ServerCommand) -> ComposerAutocompleteSuggestion {
    ComposerAutocompleteSuggestion(
      id: "command:\(command.name)",
      title: "/\(command.name)",
      subtitle: command.description ?? "Command",
      token: "/\(command.name)",
      payload: .command(command)
    )
  }

  static func fuzzy(
    _ pool: [ComposerAutocompleteSuggestion],
    query: String
  ) -> [ComposerAutocompleteSuggestion] {
    let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else { return pool }
    return pool.compactMap { item -> (ComposerAutocompleteSuggestion, Int)? in
      let title = item.title.lowercased()
      let subtitle = item.subtitle.lowercased()
      if title == needle { return (item, 0) }
      if title.hasPrefix(needle) { return (item, 1) }
      if title.contains(needle) { return (item, 2) }
      if subtitle.contains(needle) { return (item, 3) }
      return nil
    }
    .sorted { lhs, rhs in
      if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
      return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
    }
    .map(\.0)
  }
}

public enum ComposerAutocompleteProblem: Equatable, Sendable {
  case couldNotLoad
  case couldNotSearchFiles
}

public enum ComposerCatalogProblem: Equatable, Sendable {
  case couldNotLoad
}

/// A committed chip's UTF-16 span in the draft.
public struct ComposerChipRange: Equatable, Sendable {
  public var chip: ComposerMentionChip
  public var start: Int
  public var end: Int
}

public enum ComposerMentionBuilder {
  /// Locates each chip's token in the draft. A chip whose token was edited away contributes no
  /// mention, so a send can never carry a stale range.
  public static func ranges(text: String, chips: [ComposerMentionChip]) -> [ComposerChipRange] {
    let ns = text as NSString
    var searchStart = 0
    var result: [ComposerChipRange] = []
    for chip in chips {
      guard searchStart <= ns.length else { break }
      let found = ns.range(
        of: chip.token,
        options: [],
        range: NSRange(location: searchStart, length: ns.length - searchStart)
      )
      guard found.location != NSNotFound else { continue }
      let end = found.location + found.length
      let before = found.location == 0 ? nil : ns.character(at: found.location - 1)
      let after = end >= ns.length ? nil : ns.character(at: end)
      if let before, !isBoundary(before) { continue }
      if let after, !isBoundary(after) { continue }
      result.append(ComposerChipRange(chip: chip, start: found.location, end: end))
      searchStart = found.location + found.length
    }
    return result
  }

  private static func isBoundary(_ unit: unichar) -> Bool {
    guard let scalar = UnicodeScalar(unit) else { return false }
    return CharacterSet.whitespacesAndNewlines.contains(scalar)
      || CharacterSet.punctuationCharacters.contains(scalar)
  }

  public static func mentions(text: String, chips: [ComposerMentionChip]) -> AutocompleteMentions {
    var files: [FileMention] = []
    var agents: [AgentMention] = []
    var skills: [SkillMention] = []
    for range in ranges(text: text, chips: chips) {
      let mention = MentionRange(
        text: range.chip.token,
        start: range.start,
        end: range.end
      )
      switch range.chip.kind {
      case .file:
        files.append(
          FileMention(
            uri: range.chip.value,
            name: range.chip.title,
            description: range.chip.token,
            mention: mention
          )
        )
      case .agent:
        agents.append(AgentMention(name: range.chip.value, mention: mention))
      case .skill:
        skills.append(SkillMention(id: range.chip.value, mention: mention))
      case .command:
        continue
      }
    }
    return AutocompleteMentions(files: files, agents: agents, skills: skills)
  }

  /// Applies a suggestion and returns the new text and chip. The trigger range is replaced in
  /// UTF-16 offsets, never by searching for display text.
  public static func apply(
    _ suggestion: ComposerAutocompleteSuggestion,
    trigger: ComposerAutocompleteTrigger,
    to text: String
  ) -> (text: String, chip: ComposerMentionChip)? {
    let ns = text as NSString
    guard trigger.start >= 0, trigger.end >= trigger.start, trigger.end <= ns.length else {
      return nil
    }
    let replacement = suggestion.token + " "
    let updated = ns.replacingCharacters(
      in: NSRange(location: trigger.start, length: trigger.end - trigger.start),
      with: replacement
    )
    return (updated, suggestion.chip)
  }

}

private func resolvedRanges(text: String, chips: [ComposerMentionChip]) -> [ComposerChipRange] {
  ComposerMentionBuilder.ranges(text: text, chips: chips)
}
