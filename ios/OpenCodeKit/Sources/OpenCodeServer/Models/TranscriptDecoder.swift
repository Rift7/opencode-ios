import Foundation

/// Decodes `GET /api/session/{id}/message` payloads into oldest-first transcript rows. Message
/// types the transcript does not show (`synthetic` model text, `idle` successes, reasoning) still
/// contribute the rows the audited client draws — and nothing more.
public enum TranscriptDecoder {
  struct PagePayload: Decodable {
    var data: [JSONValue]
    var cursor: CursorPayload?
  }

  public static func page(from data: Data) throws -> TranscriptPage {
    let payload: PagePayload
    do {
      payload = try JSONDecoder().decode(PagePayload.self, from: data)
    } catch {
      throw OpenCodeClientError(.undecodable(feature: "transcript"))
    }
    var rows: [TranscriptItem] = []
    for message in payload.data.reversed() {
      guard let parsed = try items(from: message) else { continue }
      rows.append(contentsOf: parsed)
    }
    return TranscriptPage(items: rows, next: payload.cursor?.next)
  }

  public static func message(from data: Data) throws -> [TranscriptItem] {
    do {
      let payload = try JSONDecoder().decode(DataPayload<JSONValue>.self, from: data)
      return (try items(from: payload.data)) ?? []
    } catch let error as OpenCodeClientError {
      throw error
    } catch {
      throw OpenCodeClientError(.undecodable(feature: "message"))
    }
  }

  static func items(from value: JSONValue) throws -> [TranscriptItem]? {
    guard let object = value.objectValue else {
      throw OpenCodeClientError(.undecodable(feature: "transcript"))
    }
    guard let id = object["id"]?.stringValue, let type = object["type"]?.stringValue else {
      throw OpenCodeClientError(.undecodable(feature: "transcript"))
    }
    switch type {
    case "user":
      return userItems(id: id, object: object)
    case "assistant":
      return assistantItems(id: id, object: object)
    case "shell":
      return shellItems(id: id, object: object)
    case "skill":
      return [
        .tool(
          id: id,
          call: TranscriptToolCall(
            callID: id,
            name: "skill",
            status: .completed,
            input: object["name"]?.stringValue.map { .object(["name": .string($0)]) } ?? .null
          )
        )
      ]
    case "compaction":
      return [.compaction(id: id, info: compaction(id: id, object: object))]
    case "model-switched":
      guard let model = object["model"].flatMap(modelRef) else { return [] }
      return [
        .modelSwitch(id: id, model: model, previous: object["previous"].flatMap(modelRef), name: nil)
      ]
    case "synthetic":
      return syntheticNotice(id: id, object: object).map { [$0] } ?? []
    case "idle":
      guard object["outcome"]?.stringValue == "failed", let error = object["error"] else {
        return []
      }
      return [.runError(id: id, error: runError(error, beforeReply: true))]
    default:
      return nil
    }
  }

  // MARK: - User

  private static func userItems(id: String, object: [String: JSONValue]) -> [TranscriptItem] {
    let metadata = object["metadata"]?.objectValue
    let files = object["files"]?.arrayValue ?? []
    var items: [TranscriptItem] = []
    let images = attachedImages(files: files, messageID: id)
    if !images.isEmpty { items.append(.userImages(id: "\(id)-images", images: images)) }
    let references = TranscriptPromptText.references(metadata: metadata)
    let inline = attachedFiles(files: files, messageID: id)
    let allFiles = references.enumerated().map { index, file in
      TranscriptFile(id: "\(id)-file-\(index)", name: file.name, mime: file.mime, path: file.path)
    } + inline
    if !allFiles.isEmpty { items.append(.userFiles(id: "\(id)-files", files: allFiles)) }
    let text = TranscriptPromptText.display(
      object["text"]?.stringValue ?? "",
      references: references,
      metadata: metadata
    )
    let quotes = TranscriptPromptText.quotes(metadata)
    if !text.isEmpty || !quotes.isEmpty {
      items.append(
        .userText(id: id, text: text, source: promptSource(object), quotes: quotes)
      )
    }
    return items
  }

  private static func promptSource(_ object: [String: JSONValue]) -> TranscriptPromptSource? {
    if let origin = object["metadata"]?.objectValue?["anomaly.session"]?.objectValue?[
      "originSessionID"
    ]?.stringValue
    {
      return .session(id: origin)
    }
    if object["text"]?.stringValue?.hasPrefix("You are a subagent spawned by another session.")
      == true
    {
      return .parentAgent
    }
    return nil
  }

  private static func attachedImages(files: [JSONValue], messageID: String) -> [TranscriptImage] {
    var images: [TranscriptImage] = []
    var totalBytes = 0
    for (index, file) in files.enumerated() {
      guard images.count < 16, let object = file.objectValue else { continue }
      let fileName = lastPathComponent(object["name"]?.stringValue)
      if let placeholder = placeholderText(object),
        let parsed = TranscriptMediaReference.unavailablePlaceholder(placeholder, fallbackName: fileName),
        parsed.mime.lowercased().hasPrefix("image/")
      {
        images.append(
          TranscriptImage(
            id: "\(messageID)-img-\(index)",
            name: lastPathComponent(parsed.name),
            mime: parsed.mime,
            isUnavailable: true
          )
        )
        continue
      }
      guard let mime = object["mime"]?.stringValue?.lowercased(), mime.hasPrefix("image/") else {
        continue
      }
      if let hash = TranscriptMediaReference.hash(object["uri"]?.stringValue)
        ?? TranscriptMediaReference.hash(object["source"]?.objectValue?["uri"]?.stringValue)
      {
        images.append(
          TranscriptImage(
            id: "\(messageID)-img-\(index)",
            mediaHash: hash,
            name: fileName,
            mime: mime,
            byteCount: intValue(object["bytes"]),
            pixelWidth: intValue(object["width"]),
            pixelHeight: intValue(object["height"])
          )
        )
        continue
      }
      guard let encoded = object["data"]?.stringValue, let bytes = decodeBase64(encoded),
        bytes.count <= 20_000_000, totalBytes + bytes.count <= 32_000_000
      else { continue }
      totalBytes += bytes.count
      images.append(
        TranscriptImage(
          id: "\(messageID)-img-\(index)",
          data: bytes,
          name: fileName,
          mime: mime,
          byteCount: intValue(object["bytes"]),
          pixelWidth: intValue(object["width"]),
          pixelHeight: intValue(object["height"])
        )
      )
    }
    return images
  }

  private static func attachedFiles(files: [JSONValue], messageID: String) -> [TranscriptFile] {
    files.enumerated().compactMap { index, file in
      guard let object = file.objectValue else { return nil }
      if let placeholder = placeholderText(object),
        let parsed = TranscriptMediaReference.unavailablePlaceholder(placeholder)
      {
        guard !parsed.mime.lowercased().hasPrefix("image/") else { return nil }
        return TranscriptFile(
          id: "\(messageID)-file-inline-\(index)",
          name: lastPathComponent(parsed.name) ?? "Attached file",
          mime: parsed.mime,
          isUnavailable: true
        )
      }
      guard let mime = object["mime"]?.stringValue, !mime.lowercased().hasPrefix("image/") else {
        return nil
      }
      let attached = object["mention"] == nil
        && (TranscriptMediaReference.hash(object["uri"]?.stringValue) != nil
          || object["data"] != nil
          || object["source"]?.objectValue?["type"]?.stringValue == "inline"
          || object["source"]?.objectValue?["uri"]?.stringValue?.hasPrefix("data:") == true)
      guard attached else { return nil }
      return TranscriptFile(
        id: "\(messageID)-file-inline-\(index)",
        name: lastPathComponent(object["name"]?.stringValue) ?? "Attached file",
        mime: mime,
        mediaHash: TranscriptMediaReference.hash(object["uri"]?.stringValue),
        byteCount: intValue(object["bytes"])
      )
    }
  }

  // MARK: - Assistant

  private static func assistantItems(id: String, object: [String: JSONValue]) -> [TranscriptItem] {
    var items: [TranscriptItem] = []
    var textOrdinal = 0
    for part in object["content"]?.arrayValue ?? [] {
      guard let partObject = part.objectValue, let type = partObject["type"]?.stringValue else {
        continue
      }
      switch type {
      case "text":
        let partID = "\(id)-text-\(textOrdinal)"
        textOrdinal += 1
        guard let text = trimmed(partObject["text"]?.stringValue), !text.isEmpty else { continue }
        items.append(.assistantMarkdown(id: partID, text: text, inProgress: false))
      case "tool":
        let suffix = partObject["id"]?.stringValue ?? "unknown"
        let partID = "\(id)-tool-\(suffix)"
        let state = partObject["state"]?.objectValue
        let time = partObject["time"]?.objectValue
        let started = (time?["ran"] ?? time?["created"]).flatMap(dateFromMilliseconds)
        let completed = time?["completed"].flatMap(dateFromMilliseconds)
        items.append(
          .tool(
            id: partID,
            call: TranscriptToolCall(
              callID: partObject["id"]?.stringValue ?? partID,
              messageID: id,
              name: partObject["name"]?.stringValue ?? "tool",
              status: toolStatus(state?["status"]?.stringValue),
              input: (state?["input"] ?? .null).bounded(),
              output: toolOutput(state?["content"]?.arrayValue),
              error: state?["error"]?.objectValue?["message"]?.stringValue,
              errorType: state?["error"]?.objectValue?["type"]?.stringValue,
              metadata: (state?["metadata"]?.objectValue ?? [:]).mapValues { $0.bounded() },
              images: toolImages(state?["content"]?.arrayValue, prefix: partID),
              videos: toolVideos(state?["content"]?.arrayValue, prefix: partID),
              startedAt: started,
              completedAt: completed
            )
          )
        )
      default:
        continue
      }
    }
    if let error = object["error"] {
      items.append(.runError(id: "\(id)-error", error: runError(error)))
    } else if object["retry"]?.objectValue?["error"] != nil,
      let retry = object["retry"]?.objectValue
    {
      let error = runError(retry["error"] ?? .null)
      let at = dateFromMilliseconds(retry["at"] ?? .null) ?? Date(timeIntervalSince1970: 0)
      items.append(
        .runRetry(
          id: "\(id)-retry",
          retry: TranscriptRunRetry(attempt: intValue(retry["attempt"]) ?? 1, at: at, error: error)
        )
      )
    }
    return items
  }

  // MARK: - Shell

  private static func shellItems(id: String, object: [String: JSONValue]) -> [TranscriptItem] {
    let status = object["status"]?.stringValue
    let exit = intValue(object["exit"])
    let resolved: TranscriptToolCall.Status =
      status == "running" ? .running : (status == "exited" && (exit == nil || exit == 0) ? .completed : .error)
    var metadata: [String: JSONValue] = [:]
    if let exit { metadata["exit"] = .number(Double(exit)) }
    return [
      .tool(
        id: id,
        call: TranscriptToolCall(
          callID: object["shellID"]?.stringValue ?? id,
          messageID: id,
          name: "shell",
          status: resolved,
          input: .object(["command": .string(object["command"]?.stringValue ?? "")]),
          output: object["output"]?.objectValue?["output"]?.stringValue.map { [bounded($0, 20_000)] } ?? [],
          metadata: metadata
        )
      )
    ]
  }

  // MARK: - Synthetic

  private static func syntheticNotice(id: String, object: [String: JSONValue]) -> TranscriptItem? {
    guard let description = trimmed(object["description"]?.stringValue), !description.isEmpty else {
      return nil
    }
    let metadata = object["metadata"]?.objectValue
    let source = metadata?["source"]?.stringValue
    let state = metadata?["state"]?.stringValue
    let exit = metadata?["exit"]?.numberValue
    let timedOut = metadata?["timeout"]?.boolValue == true
    let failed = state == "error"
      || (source == "shell" && state == "completed" && (timedOut || (exit.map { $0 != 0 } ?? false)))
    let actor: TranscriptNoticeKind.Source? =
      source == "shell" ? .shell : (source == "subagent" ? .subagent : nil)
    let kind = actor.map { actor in
      TranscriptNoticeKind(
        source: actor,
        outcome: failed ? .failed : (state == "cancelled" ? .cancelled : .finished)
      )
    }
    return .notice(
      id: id,
      text: description,
      isError: failed,
      kind: kind,
      agent: metadata?["agent"]?.stringValue
    )
  }

  // MARK: - Shared

  private static func compaction(id: String, object: [String: JSONValue]) -> TranscriptCompaction {
    let status: TranscriptCompaction.Status
    if object["status"]?.stringValue == "running" {
      status = .running
    } else if object["status"]?.stringValue == "failed",
      object["error"]?.objectValue?["type"]?.stringValue == "aborted"
    {
      status = .cancelled
    } else if object["status"]?.stringValue == "failed" {
      status = .failed
    } else {
      status = .completed
    }
    let tokens = object["tokens"]?.objectValue
    var inputTokens: Int?
    var outputTokens: Int?
    if status != .running, let tokens {
      let cache = tokens["cache"]?.objectValue
      let input = (tokens["input"]?.numberValue ?? 0) + (cache?["read"]?.numberValue ?? 0)
        + (cache?["write"]?.numberValue ?? 0)
      let output = (tokens["output"]?.numberValue ?? 0) + (tokens["reasoning"]?.numberValue ?? 0)
      if input + output > 0 {
        inputTokens = Int(input)
        outputTokens = Int(output)
      }
    }
    let providerContext = object["providerContext"] != nil && object["providerContext"] != .null
    return TranscriptCompaction(
      status: status,
      isProvider: status == .completed && providerContext,
      summary: bounded(trimmed(object["summary"]?.stringValue) ?? "", 20_000),
      errorMessage: status == .failed ? trimmed(object["error"]?.objectValue?["message"]?.stringValue) : nil,
      inputTokens: inputTokens,
      outputTokens: outputTokens
    )
  }

  private static func runError(_ value: JSONValue, beforeReply: Bool = false) -> TranscriptRunError {
    let object = value.objectValue ?? [:]
    return TranscriptRunError(
      type: object["type"]?.stringValue ?? "unknown",
      message: object["message"]?.stringValue ?? "",
      status: intValue(object["status"]),
      beforeReply: beforeReply
    )
  }

  private static func toolStatus(_ raw: String?) -> TranscriptToolCall.Status {
    TranscriptToolCall.Status(rawValue: raw ?? "") ?? .completed
  }

  private static func toolOutput(_ content: [JSONValue]?) -> [String] {
    (content ?? []).compactMap { part in
      guard part.objectValue?["type"]?.stringValue == "text" else { return nil }
      return part.objectValue?["text"]?.stringValue.map { bounded($0, 20_000) }
    }
  }

  private static func toolImages(_ content: [JSONValue]?, prefix: String) -> [TranscriptImage] {
    var images: [TranscriptImage] = []
    var totalBytes = 0
    for (index, part) in (content ?? []).enumerated() {
      guard images.count < 16, let object = part.objectValue else { continue }
      if object["type"]?.stringValue == "text",
        let text = object["text"]?.stringValue,
        let placeholder = TranscriptMediaReference.unavailablePlaceholder(text),
        placeholder.mime.lowercased().hasPrefix("image/")
      {
        images.append(
          TranscriptImage(
            id: "\(prefix)-image-\(index)",
            name: lastPathComponent(placeholder.name),
            mime: placeholder.mime,
            isUnavailable: true
          )
        )
        continue
      }
      guard object["type"]?.stringValue == "file",
        let mime = object["mime"]?.stringValue?.lowercased(),
        mime.hasPrefix("image/"),
        let uri = object["uri"]?.stringValue
      else { continue }
      if let hash = TranscriptMediaReference.hash(uri) {
        images.append(
          TranscriptImage(
            id: "\(prefix)-image-\(index)",
            mediaHash: hash,
            name: lastPathComponent(object["name"]?.stringValue),
            mime: mime,
            byteCount: intValue(object["bytes"]),
            pixelWidth: intValue(object["width"]),
            pixelHeight: intValue(object["height"])
          )
        )
        continue
      }
      guard let comma = uri.firstIndex(of: ",") else { continue }
      let header = uri[..<comma].lowercased()
      guard header.hasPrefix("data:\(mime)"), header.hasSuffix(";base64") else { continue }
      let encoded = String(uri[uri.index(after: comma)...])
      guard encoded.count <= (20_000_000 * 4 / 3) + 4, let bytes = decodeBase64(encoded),
        bytes.count <= 20_000_000, totalBytes + bytes.count <= 32_000_000
      else { continue }
      totalBytes += bytes.count
      images.append(
        TranscriptImage(
          id: "\(prefix)-image-\(index)",
          data: bytes,
          mime: mime,
          byteCount: bytes.count
        )
      )
    }
    return images
  }

  private static func toolVideos(_ content: [JSONValue]?, prefix: String) -> [TranscriptFile] {
    (content ?? []).enumerated().compactMap { index, part in
      guard let object = part.objectValue,
        object["type"]?.stringValue == "file",
        let mime = object["mime"]?.stringValue,
        mime.lowercased().hasPrefix("video/"),
        let hash = TranscriptMediaReference.hash(object["uri"]?.stringValue)
      else { return nil }
      return TranscriptFile(
        id: "\(prefix)-video-\(index)",
        name: lastPathComponent(object["name"]?.stringValue) ?? "Video",
        mime: mime,
        mediaHash: hash,
        byteCount: intValue(object["bytes"])
      )
    }
  }

  private static func modelRef(_ value: JSONValue) -> TranscriptModelRef? {
    guard let object = value.objectValue, let id = object["id"]?.stringValue,
      let provider = object["providerID"]?.stringValue
    else { return nil }
    return TranscriptModelRef(id: id, providerID: provider, variant: object["variant"]?.stringValue)
  }

  private static func placeholderText(_ object: [String: JSONValue]) -> String? {
    guard object["mime"]?.stringValue?.lowercased().hasPrefix("image/") != true else { return nil }
    guard let encoded = object["data"]?.stringValue, encoded.utf8.count <= 4_096 else { return nil }
    if let bytes = decodeBase64(encoded), let text = String(data: bytes, encoding: .utf8) {
      return text
    }
    return encoded
  }

  private static func dateFromMilliseconds(_ value: JSONValue) -> Date? {
    guard let ms = value.numberValue else { return nil }
    return Date(timeIntervalSince1970: ms / 1_000)
  }

  private static func intValue(_ value: JSONValue?) -> Int? {
    value?.numberValue.map { Int($0) }
  }

  private static func lastPathComponent(_ name: String?) -> String? {
    name?.split(separator: "/").last.map(String.init)
  }

  private static func trimmed(_ text: String?) -> String? {
    text?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// At most `limit` UTF-8 bytes, cut on a character boundary.
  public static func bounded(_ text: String, _ limit: Int) -> String {
    guard text.utf8.count > limit else { return text }
    var used = 0
    var result = ""
    for character in text {
      let size = String(character).utf8.count
      if used + size > limit - 3 { break }
      result.append(character)
      used += size
    }
    return result + "\n… output truncated"
  }

  static func decodeBase64(_ text: String) -> Data? {
    guard text.count % 4 == 0 else { return nil }
    return Data(base64Encoded: text)
  }
}

extension JSONValue {
  /// Bounds a server-defined value before it becomes transcript state.
  public func bounded(stringLimit: Int = 20_000, collectionLimit: Int = 100) -> JSONValue {
    switch self {
    case .string(let value): return .string(TranscriptDecoder.bounded(value, stringLimit))
    case .array(let values): return .array(values.prefix(collectionLimit).map { $0.bounded(stringLimit: stringLimit, collectionLimit: collectionLimit) })
    case .object(let values):
      let keys = values.count <= collectionLimit ? values.keys.sorted() : Array(values.keys.sorted().prefix(collectionLimit))
      var bounded: [String: JSONValue] = [:]
      for key in keys {
        bounded[key] = values[key]?.bounded(stringLimit: stringLimit, collectionLimit: collectionLimit)
      }
      return .object(bounded)
    case .number, .bool, .null: return self
    }
  }
}
