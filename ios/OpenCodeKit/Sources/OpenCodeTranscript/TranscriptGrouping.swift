import Foundation
import OpenCodeServer

/// One list-sized unit of transcript presentation. Grouping is pure so a snapshot can be
/// projected and tested without building a view.
public enum TranscriptEntry: Equatable, Sendable, Identifiable {
  case single(TranscriptItem)
  case userGroup(id: String, items: [TranscriptItem], startsTurn: Bool)
  case toolGroup(id: String, tools: [TranscriptItem])
  case replyEnd(id: String, texts: [String])

  public var id: String {
    switch self {
    case .single(let item): return item.id
    case .userGroup(let id, _, _): return "user-\(id)"
    case .toolGroup(let id, _): return "group-\(id)"
    case .replyEnd(let id, _): return id
    }
  }

  public var itemIDs: [String] {
    switch self {
    case .single(let item): return [item.id]
    case .userGroup(_, let items, _): return items.map(\.id)
    case .toolGroup(_, let tools): return tools.map(\.id)
    case .replyEnd: return []
    }
  }

  public var groupMembers: [TranscriptItem]? {
    switch self {
    case .toolGroup(_, let tools): return tools
    case .userGroup(_, let items, _): return items
    default: return nil
    }
  }

  public var userMessageID: String? {
    guard case .userGroup(_, let items, _) = self else { return nil }
    return items.first?.promptID
  }

  public var toolCalls: [TranscriptToolCall] {
    switch self {
    case .single(.tool(_, let call)): return [call]
    case .toolGroup(_, let tools):
      return tools.compactMap {
        if case .tool(_, let call) = $0 { return call }
        return nil
      }
    default: return []
    }
  }

  public var subagentSessionIDs: [String] {
    toolCalls.compactMap { call in
      guard call.name == "subagent" || call.name == "task" else { return nil }
      return call.metadata["sessionID"]?.stringValue
    }
  }

  public var layoutKind: String {
    switch self {
    case .userGroup: return "user"
    case .toolGroup: return "tools"
    case .replyEnd: return "reply-end"
    case .single(let item):
      switch item {
      case .assistantMarkdown(_, let text, _):
        if text.contains("\n|") || text.hasPrefix("|") { return "table" }
        if text.contains("```") { return "code" }
        return "markdown"
      case .compaction: return "compaction"
      case .modelSwitch: return "model-switch"
      default: return "other"
      }
    }
  }
}

public enum TranscriptGrouping {
  /// Groups raw rows into what the list draws. Each finished reply ends with a Copy row; the
  /// last reply only once the run stops.
  public static func build(
    items: [TranscriptItem],
    isRunning: Bool = false,
    sessionStartModels: Set<String>? = nil
  ) -> [TranscriptEntry] {
    let startModels = sessionStartModels ?? sessionStartModelIDs(items)
    var entries: [TranscriptEntry] = []
    var run: [TranscriptItem] = []
    var kind: RunKind?
    var reply: [String] = []
    var replyID: String?
    var turnHasRunError = false

    func flush() {
      if let kind {
        switch kind {
        case .tools:
          if let first = run.first {
            entries.append(.toolGroup(id: first.id, tools: run))
          }
        case .user:
          if let first = run.first {
            let startsTurn = entries.last.map { entry in
              if case .userGroup = entry { return false }
              return true
            } ?? true
            entries.append(.userGroup(id: first.id, items: run, startsTurn: startsTurn))
          }
        }
      }
      run.removeAll(keepingCapacity: true)
      kind = nil
    }

    func append(_ item: TranscriptItem, as next: RunKind) {
      if kind != next { flush() }
      kind = next
      run.append(item)
    }

    func endReply() {
      if let replyID, !reply.isEmpty {
        flush()
        entries.append(.replyEnd(id: "reply-end-\(replyID)", texts: reply))
      }
      reply.removeAll(keepingCapacity: true)
      replyID = nil
    }

    for (index, item) in items.enumerated() {
      switch item {
      case .tool(_, let call) where isPendingQuestion(call):
        if isRunningOrStreaming(call) { continue }
        flush()
        entries.append(.single(item))

      case .tool, .notice:
        append(item, as: .tools)

      case .userText, .userImages, .userFiles:
        endReply()
        turnHasRunError = false
        append(item, as: .user(item.promptID ?? item.id))

      case .runError(_, let error):
        if error.beforeReply, turnHasRunError { continue }
        turnHasRunError = true
        flush()
        entries.append(.single(item))

      case .assistantMarkdown(_, let text, _):
        flush()
        entries.append(.single(item))
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          reply.append(text)
        }
        replyID = item.id

      case .compaction, .info, .undone:
        flush()
        entries.append(.single(item))

      case .modelSwitch(_, _, _, let name):
        if startModels.contains(item.id) { continue }
        if switchEndsReply(index: index, items: items, isRunning: isRunning) { endReply() }
        flush()
        if case .modelSwitch(let id, let model, let previous, _) = item {
          entries.append(.single(.modelSwitch(id: id, model: model, previous: previous, name: name)))
        }

      case .sendFailure, .runRetry:
        continue
      }
    }
    flush()
    if !isRunning { endReply() }
    return entries
  }

  /// A session created without a model gets its first one as a switch from nothing.
  public static func sessionStartModelIDs(_ items: [TranscriptItem]) -> Set<String> {
    var ids: Set<String> = []
    for item in items {
      guard case .modelSwitch(let id, _, let previous, _) = item else { return ids }
      if previous == nil { ids.insert(id) }
    }
    return ids
  }

  /// Where a window starting at `index` may start without splitting a tool group or a send.
  public static func entryStart(_ index: Int, items: [TranscriptItem]) -> Int {
    guard index > 0, index < items.count else { return index }
    func kind(_ item: TranscriptItem) -> String {
      switch item {
      case .tool(_, let call) where isPendingQuestion(call):
        return isRunningOrStreaming(call) ? "passes" : "breaks"
      case .tool, .notice:
        return "run:tools"
      case .userText, .userImages, .userFiles:
        return "run:user:\(item.promptID ?? item.id)"
      case .sendFailure, .runRetry:
        return "passes"
      default:
        return "breaks"
      }
    }
    var first = index
    while first < items.count, kind(items[first]) == "passes" { first += 1 }
    guard first < items.count, kind(items[first]).hasPrefix("run:") else { return index }
    let run = kind(items[first])
    var start = index
    var previous = index - 1
    while previous >= 0 {
      let candidate = kind(items[previous])
      if candidate == "passes" {
        // Keep walking; a notice can move between groups.
      } else if candidate == run {
        start = previous
      } else {
        return start
      }
      previous -= 1
    }
    return start
  }

  /// A window of the last `limit` entries, expanded to a group boundary.
  public static func window(
    _ entries: [TranscriptEntry],
    limit: Int,
    startAt anchorID: String? = nil
  ) -> ArraySlice<TranscriptEntry> {
    guard !entries.isEmpty else { return [] }
    let latest = max(0, entries.count - max(0, limit))
    var start = latest
    if let anchorID, let index = entries.firstIndex(where: { $0.id == anchorID }) {
      start = min(latest, index)
    }
    return entries[start...]
  }

  static func isPendingQuestion(_ call: TranscriptToolCall) -> Bool {
    call.name == "question" && (call.status == .running || call.status == .streaming)
  }

  static func isRunningOrStreaming(_ call: TranscriptToolCall) -> Bool {
    call.status == .running || call.status == .streaming
  }

  private static func switchEndsReply(
    index: Int,
    items: [TranscriptItem],
    isRunning: Bool
  ) -> Bool {
    guard index + 1 < items.count else { return !isRunning }
    for item in items[(index + 1)...] {
      switch item {
      case .userText, .userImages, .userFiles: return true
      case .assistantMarkdown: return false
      default: continue
      }
    }
    return !isRunning
  }

  private enum RunKind: Equatable {
    case tools
    case user(String)
  }
}
