import Foundation

/// A stable row of transcript content. IDs are the server's message and part identities, so a
/// REST replacement and a live projection update the same row.
public enum TranscriptItem: Equatable, Sendable, Identifiable {
  case userText(id: String, text: String, source: TranscriptPromptSource?, quotes: [TranscriptQuote])
  case userImages(id: String, images: [TranscriptImage])
  case userFiles(id: String, files: [TranscriptFile])
  case assistantMarkdown(id: String, text: String, inProgress: Bool)
  case tool(id: String, call: TranscriptToolCall)
  case compaction(id: String, info: TranscriptCompaction?)
  case info(id: String, text: String)
  case modelSwitch(id: String, model: TranscriptModelRef, previous: TranscriptModelRef?, name: String?)
  case notice(
    id: String,
    text: String,
    isError: Bool,
    kind: TranscriptNoticeKind?,
    agent: String?
  )
  case sendFailure(id: String, message: String)
  case runError(id: String, error: TranscriptRunError)
  case runRetry(id: String, retry: TranscriptRunRetry)
  case undone(id: String, messages: Int)

  public var id: String {
    switch self {
    case .userText(let id, _, _, _), .userImages(let id, _), .userFiles(let id, _),
      .assistantMarkdown(let id, _, _), .tool(let id, _), .compaction(let id, _),
      .info(let id, _), .modelSwitch(let id, _, _, _), .notice(let id, _, _, _, _),
      .sendFailure(let id, _), .runError(let id, _), .runRetry(let id, _), .undone(let id, _):
      return id
    }
  }

  /// Text still arriving from the event stream; REST has no durable copy yet.
  public var isInProgressText: Bool {
    if case .assistantMarkdown(_, _, let inProgress) = self { return inProgress }
    return false
  }

  /// The server message this row belongs to.
  public var messageID: String {
    switch self {
    case .userText(let id, _, _, _): return id
    case .userImages(let id, _): return id.hasSuffix("-images") ? String(id.dropLast(7)) : id
    case .userFiles(let id, _): return id.hasSuffix("-files") ? String(id.dropLast(6)) : id
    case .assistantMarkdown(let id, _, _):
      return id.range(of: "-text-", options: .backwards).map { String(id[..<$0.lowerBound]) } ?? id
    case .tool(let id, let call):
      if let messageID = call.messageID { return messageID }
      return id.range(of: "-tool-").map { String(id[..<$0.lowerBound]) } ?? id
    case .runError(let id, let error):
      if error.beforeReply { return id }
      return id.hasSuffix("-error") ? String(id.dropLast(6)) : id
    case .runRetry(let id, _): return id.hasSuffix("-retry") ? String(id.dropLast(6)) : id
    default: return id
    }
  }

  /// The prompt id shared by a user message's images, files and text rows.
  public var promptID: String? {
    switch self {
    case .userText(let id, _, _, _): return id
    case .userImages(let id, _): return id.hasSuffix("-images") ? String(id.dropLast(7)) : nil
    case .userFiles(let id, _): return id.hasSuffix("-files") ? String(id.dropLast(6)) : nil
    default: return nil
    }
  }
}

public enum TranscriptPromptSource: Equatable, Sendable {
  case session(id: String)
  case parentAgent
}

public struct TranscriptQuote: Equatable, Sendable {
  public var text: String
  public var comment: String?

  public init(text: String, comment: String? = nil) {
    self.text = text
    self.comment = comment
  }
}

public struct TranscriptFile: Equatable, Sendable, Identifiable {
  public var id: String
  public var name: String?
  public var mime: String?
  public var path: String?
  public var mediaHash: String?
  public var byteCount: Int?
  public var isUnavailable: Bool

  public init(
    id: String,
    name: String? = nil,
    mime: String? = nil,
    path: String? = nil,
    mediaHash: String? = nil,
    byteCount: Int? = nil,
    isUnavailable: Bool = false
  ) {
    self.id = id
    self.name = name
    self.mime = mime
    self.path = path
    self.mediaHash = mediaHash
    self.byteCount = byteCount
    self.isUnavailable = isUnavailable
  }
}

public struct TranscriptImage: Equatable, Sendable, Identifiable {
  public var id: String
  public var data: Data
  public var mediaHash: String?
  public var name: String?
  public var mime: String?
  public var byteCount: Int?
  public var pixelWidth: Int?
  public var pixelHeight: Int?
  public var isUnavailable: Bool

  public init(
    id: String,
    data: Data = Data(),
    mediaHash: String? = nil,
    name: String? = nil,
    mime: String? = nil,
    byteCount: Int? = nil,
    pixelWidth: Int? = nil,
    pixelHeight: Int? = nil,
    isUnavailable: Bool = false
  ) {
    self.id = id
    self.data = data
    self.mediaHash = mediaHash
    self.name = name
    self.mime = mime
    self.byteCount = byteCount
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.isUnavailable = isUnavailable
  }

  public var aspectRatio: Double? {
    guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
    return Double(pixelWidth) / Double(pixelHeight)
  }
}

public struct TranscriptToolCall: Equatable, Sendable {
  public enum Status: String, Equatable, Sendable {
    case streaming
    case running
    case completed
    case error
  }

  public var callID: String
  public var messageID: String?
  public var name: String
  public var status: Status
  public var input: JSONValue
  /// Streaming input text before the server parses it into `input`.
  public var inputText: String
  public var output: [String]
  public var error: String?
  public var errorType: String?
  public var metadata: [String: JSONValue]
  public var images: [TranscriptImage]
  public var videos: [TranscriptFile]
  public var startedAt: Date?
  public var completedAt: Date?

  public init(
    callID: String,
    messageID: String? = nil,
    name: String,
    status: Status,
    input: JSONValue = .null,
    inputText: String = "",
    output: [String] = [],
    error: String? = nil,
    errorType: String? = nil,
    metadata: [String: JSONValue] = [:],
    images: [TranscriptImage] = [],
    videos: [TranscriptFile] = [],
    startedAt: Date? = nil,
    completedAt: Date? = nil
  ) {
    self.callID = callID
    self.messageID = messageID
    self.name = name
    self.status = status
    self.input = input
    self.inputText = inputText
    self.output = output
    self.error = error
    self.errorType = errorType
    self.metadata = metadata
    self.images = images
    self.videos = videos
    self.startedAt = startedAt
    self.completedAt = completedAt
  }

  public var isShell: Bool { name == "shell" || name == "bash" }

  /// The row title shared with the Used N summary.
  public var displayName: String {
    if name == "bash" { return TranscriptToolCall.shellName }
    var bare = name
    if bare.hasPrefix("opencode_"), bare.count > 9 { bare.removeFirst(9) }
    let words = bare.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    guard let first = words.first else { return words }
    return first.uppercased() + words.dropFirst()
  }

  /// A read, write, or edit target (`path`, `filePath`, `file_path`).
  public var inputPath: String? {
    for key in ["path", "filePath", "file_path"] {
      if let value = input[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty
      {
        return value
      }
    }
    return nil
  }

  /// The row's one-line detail: command, file name, pattern, URL or query.
  public var subtitle: String? {
    if isShell { return inputFirstLine("command") }
    if name == "execute" {
      if let code = inputFirstLine("code") { return code }
    }
    if let path = inputPath {
      let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
      return trimmed.split(separator: "/").last.map(String.init) ?? path
    }
    for key in ["pattern", "url", "query", "description", "name"] {
      if let value = inputFirstLine(key) { return value }
    }
    return nil
  }

  /// Readable arguments for the expanded row; structured values are compact JSON.
  public var arguments: [(String, String)] {
    guard let object = input.objectValue else {
      if let raw = input.stringValue, !raw.isEmpty { return [("input", raw)] }
      return []
    }
    return object.keys.sorted().compactMap { key in
      if isShell, key == "command" || key == "description" { return nil }
      guard let value = object[key] else { return nil }
      switch value {
      case .null: return nil
      case .string(let text): return (key, text)
      case .bool(let flag): return (key, flag ? "true" : "false")
      case .number(let number): return (key, Self.plainNumber(number))
      case .array, .object: return (key, value.compactJSON)
      }
    }
  }

  public var outputText: String { output.joined(separator: "\n") }

  public var shellExit: Int? {
    metadata["exit"]?.numberValue.map { Int($0) }
  }

  private func inputFirstLine(_ key: String) -> String? {
    guard let value = input[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return nil }
    return value.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? value
  }

  static let shellName = "Shell"

  private static func plainNumber(_ number: Double) -> String {
    if number.rounded() == number, abs(number) < 1_000_000_000 {
      return String(Int(number))
    }
    return String(number)
  }
}

public struct TranscriptCompaction: Equatable, Sendable {
  public enum Status: String, Equatable, Sendable {
    case running
    case completed
    case failed
    case cancelled
  }

  public var status: Status
  public var isProvider: Bool
  public var summary: String
  public var errorMessage: String?
  public var inputTokens: Int?
  public var outputTokens: Int?

  public init(
    status: Status,
    isProvider: Bool = false,
    summary: String = "",
    errorMessage: String? = nil,
    inputTokens: Int? = nil,
    outputTokens: Int? = nil
  ) {
    self.status = status
    self.isProvider = isProvider
    self.summary = summary
    self.errorMessage = errorMessage
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
  }
}

public struct TranscriptModelRef: Equatable, Sendable {
  public var id: String
  public var providerID: String
  public var variant: String?

  public init(id: String, providerID: String, variant: String? = nil) {
    self.id = id
    self.providerID = providerID
    self.variant = variant
  }

  public var displayID: String { "\(providerID)/\(id)" }
}

public struct TranscriptNoticeKind: Equatable, Sendable {
  public enum Source: String, Equatable, Sendable {
    case shell
    case subagent
  }

  public enum Outcome: String, Equatable, Sendable {
    case finished
    case failed
    case cancelled
  }

  public var source: Source
  public var outcome: Outcome

  public init(source: Source, outcome: Outcome) {
    self.source = source
    self.outcome = outcome
  }
}

public struct TranscriptRunError: Equatable, Sendable {
  public var type: String
  public var message: String
  public var status: Int?
  public var beforeReply: Bool

  public init(type: String, message: String, status: Int? = nil, beforeReply: Bool = false) {
    self.type = type
    self.message = message
    self.status = status
    self.beforeReply = beforeReply
  }

  public var isStop: Bool { type == "aborted" || type == "permission.rejected" }

  public var isContextOverflow: Bool {
    let text = message.lowercased()
    return [
      "prompt is too long", "context length", "context_length_exceeded", "context window",
      "maximum context", "too many tokens", "input is too long", "exceeds the context",
    ].contains { text.contains($0) }
  }

  public var isOverloaded: Bool {
    status == 529 || message.lowercased().contains("overloaded")
  }
}

public struct TranscriptRunRetry: Equatable, Sendable {
  public var attempt: Int
  public var at: Date
  public var error: TranscriptRunError

  public init(attempt: Int, at: Date, error: TranscriptRunError) {
    self.attempt = attempt
    self.at = at
    self.error = error
  }
}

public struct TranscriptPage: Equatable, Sendable {
  /// Oldest first, as the list and grouping expect.
  public var items: [TranscriptItem]
  /// The cursor of the next older page, nil at the start of the history.
  public var next: String?

  public init(items: [TranscriptItem], next: String? = nil) {
    self.items = items
    self.next = next
  }
}

public enum TranscriptMediaReference {
  public static let prefix = "media:"
  public static let capability = "experimental-media-uri"

  public static func hash(_ text: String?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
      trimmed.hasPrefix(prefix)
    else { return nil }
    let hash = String(trimmed.dropFirst(prefix.count))
    return isValidHash(hash) ? hash : nil
  }

  public static func isValidHash(_ hash: String) -> Bool {
    hash.count == 64 && hash.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
  }

  public static func unavailablePlaceholder(
    _ text: String,
    fallbackName: String? = nil
  ) -> (name: String?, mime: String)? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let open = "[media unavailable: "
    guard trimmed.hasPrefix(open), trimmed.hasSuffix("]"), trimmed.count > open.count + 1 else {
      return nil
    }
    let body = String(trimmed.dropFirst(open.count).dropLast()).trimmingCharacters(in: .whitespaces)
    guard !body.isEmpty else { return nil }
    if body.hasSuffix(")"), let openParen = body.range(of: " (", options: .backwards) {
      let name = String(body[..<openParen.lowerBound]).trimmingCharacters(in: .whitespaces)
      let mime = String(body[openParen.upperBound...].dropLast()).trimmingCharacters(in: .whitespaces)
      guard !mime.isEmpty else { return nil }
      return (name.isEmpty ? fallbackName : name, mime)
    }
    return (fallbackName, body)
  }
}

/// Resolves the prompt text a reader sees: the typed words without the model-only attachment
/// lines and browser page block.
public enum TranscriptPromptText {
  public static func display(
    _ text: String,
    references: [TranscriptFile],
    metadata: [String: JSONValue]?
  ) -> String {
    if !quotes(metadata).isEmpty, let explicit = metadata?["displayText"]?.stringValue {
      return explicit.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var stripped = text
    if metadata?["page"] != nil {
      stripped = removingPageBlock(stripped)
    }
    guard !references.isEmpty else {
      return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let lines = Set(references.compactMap { file -> String? in
      guard let path = file.path else { return nil }
      return "Attached file: `\(path)`"
    })
    return
      stripped
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
      .filter { !lines.contains($0) }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func references(metadata: [String: JSONValue]?) -> [TranscriptFile] {
    guard let items = metadata?["attachments"]?.arrayValue else { return [] }
    return items.enumerated().compactMap { index, item in
      guard let object = item.objectValue,
        let name = object["name"]?.stringValue,
        let mime = object["mime"]?.stringValue,
        let path = object["path"]?.stringValue
      else { return nil }
      return TranscriptFile(id: "reference-\(index)", name: name, mime: mime, path: path)
    }
  }

  public static func quotes(_ metadata: [String: JSONValue]?) -> [TranscriptQuote] {
    guard let items = metadata?["comments"]?.arrayValue else { return [] }
    return items.compactMap { item in
      guard let object = item.objectValue,
        object["type"]?.stringValue == "quote",
        let text = object["text"]?.stringValue
      else { return nil }
      let comment = object["comment"]?.stringValue?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return TranscriptQuote(text: text, comment: (comment?.isEmpty ?? true) ? nil : comment)
    }
  }

  private static let pageBlock = #"\s*<page url="[^"]*"[^>]*>[\s\S]*</page>\s*$"#

  static func removingPageBlock(_ text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pageBlock) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range),
      let swiftRange = Range(match.range, in: text)
    else { return text }
    return String(text[..<swiftRange.lowerBound])
  }
}

extension JSONValue {
  public var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  var compactJSON: String {
    switch self {
    case .string(let value): return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    case .number(let value):
      return value.rounded() == value && abs(value) < 1_000_000_000
        ? String(Int(value)) : String(value)
    case .bool(let value): return value ? "true" : "false"
    case .null: return "null"
    case .array(let values): return "[" + values.map(\.compactJSON).joined(separator: ",") + "]"
    case .object(let values):
      let body = values.keys.sorted().map { key in
        "\"\(key)\":\(values[key]?.compactJSON ?? "null")"
      }
      return "{" + body.joined(separator: ",") + "}"
    }
  }
}
