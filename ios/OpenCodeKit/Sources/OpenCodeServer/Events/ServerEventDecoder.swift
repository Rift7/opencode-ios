import Foundation

/// A frame the app cannot use, or one that reports a server-side failure.
public enum ServerEventError: Error, Equatable, Sendable {
  /// The server reported a failed request as an event (`_tag`), not a domain event.
  case serverFailure
}

/// The fields events carry. Any type mismatch drops `data` for that frame, so one unreadable event
/// never costs the connection.
struct EventPayload: Codable, Sendable {
  var sessionID: String?
  var parentID: String?
  /// `session.viewed`'s idle watermark, in epoch milliseconds.
  var idle: Double?
  var inboxID: String?
  var title: String?
  var form: Form?
  var assistantMessageID: String?
  var ordinal: Int?
  var delta: String?
  var text: String?
  var id: String?
  var name: String?
  /// `session.execution.interrupted`'s cause.
  var reason: String?
  var canonical: String?
  var repository: String?
  var icon: ServerProject.ProjectIcon?
  var input: JSONValue?
  var metadata: [String: JSONValue]?
  var content: [Content]?
  var error: ErrorPayload?
  var info: ShellInfoPayload?
  var revert: Revert?
  var location: Lenient<Location>?

  struct Form: Codable, Sendable {
    var sessionID: String
  }

  struct Location: Codable, Sendable {
    var directory: String?
  }

  struct Content: Codable, Sendable {
    var type: String
    var text: String?
  }

  struct Revert: Codable, Sendable {
    var messageID: String
  }

  /// `content` entries that are text, in order.
  var textOutput: [String] {
    (content ?? []).filter { $0.type == "text" }.compactMap(\.text)
  }
}

struct ErrorPayload: Codable, Sendable {
  var type: String?
  var message: String?
  var status: Int?
}

/// Every event type the audited client handles. An unhandled type skips decoding `data` entirely, so
/// a newer server's event costs nothing.
enum HandledEventTypes {
  static let all: Set<String> = [
    "server.connected",
    "session.execution.started",
    "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted",
    "session.created", "session.forked", "session.viewed",
    "session.revert.staged", "session.revert.cleared", "session.revert.committed",
    "session.renamed", "session.deleted", "session.archived", "session.unarchived",
    "session.inbox.cancelled", "session.inbox.enqueued", "session.inbox.delivery.changed",
    "session.inbox.delivered",
    "session.step.started", "session.step.streamed", "session.step.ended", "session.step.failed",
    "session.text.started", "session.text.delta", "session.text.ended",
    "session.reasoning.started", "session.reasoning.delta", "session.reasoning.ended",
    "session.tool.input.started", "session.tool.input.delta", "session.tool.input.ended",
    "session.tool.called", "session.tool.progress", "session.tool.success", "session.tool.failed",
    "session.message.content.updated", "session.synthetic", "session.instructions.updated",
    "session.agent.selected", "session.model.selected", "session.moved", "session.permissions",
    "session.retry.scheduled", "session.compaction.started",
    "session.compaction.ended", "session.compaction.failed", "session.shell.started",
    "session.shell.ended",
    "permission.asked", "form.created", "permission.replied", "form.replied", "form.cancelled",
    "shell.created", "shell.exited", "shell.deleted", "experimental.job.updated",
    "project.updated",
    "model.updated", "provider.updated", "agent.updated",
  ]
}

/// One SSE `data:` payload: nil for a frame the app ignores, and a thrown `serverFailure` for the
/// server's own error frame.
public enum ServerEventDecoder {
  /// Decodes one `data:` payload. Throws `ServerEventError.serverFailure` when the frame reports a
  /// failed request.
  public static func decode(_ text: String) throws -> ServerEvent? {
    guard let data = text.data(using: .utf8),
      let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
    else { return nil }
    if envelope.tag != nil { throw ServerEventError.serverFailure }
    guard let type = envelope.type, HandledEventTypes.all.contains(type) else { return nil }
    if type == "experimental.job.updated" {
      return decodeJobUpdated(envelope.data)
    }
    let payload: EventPayload?
    if let value = envelope.data, value != .null {
      payload = try? JSONDecoder().decode(EventPayload.self, from: JSONEncoder().encode(value))
    } else {
      payload = nil
    }
    return event(type: type, data: payload)
  }

  private struct Envelope: Decodable {
    var type: String?
    var tag: String?
    var data: JSONValue?

    enum CodingKeys: String, CodingKey {
      case type
      case tag = "_tag"
      case data
    }
  }

  private static func decodeJobUpdated(_ element: JSONValue?) -> ServerEvent? {
    guard let info = element?["info"],
      let payload = try? JSONDecoder().decode(JobInfoPayload.self, from: JSONEncoder().encode(info))
    else { return nil }
    return .jobUpdated(payload.job)
  }

  private static func event(type: String, data: EventPayload?) -> ServerEvent? {
    func content(_ make: (String) -> LiveContentEvent) -> ServerEvent? {
      guard let sessionID = data?.sessionID, let messageID = data?.assistantMessageID else { return nil }
      return .contentBatch(sessionID: sessionID, events: [make(messageID)])
    }
    func ordinalContent(_ make: (String, Int) -> LiveContentEvent) -> ServerEvent? {
      guard let ordinal = data?.ordinal else { return nil }
      return content { make($0, ordinal) }
    }
    func toolContent(_ make: (String, String, EventPayload) -> LiveContentEvent) -> ServerEvent? {
      guard let payload = data, let toolID = payload.id else { return nil }
      return content { make($0, toolID, payload) }
    }

    switch type {
    case "server.connected":
      return .connected
    case "session.execution.started":
      return data?.sessionID.map(ServerEvent.executionStarted)
    case "session.execution.succeeded", "session.execution.failed":
      return data?.sessionID.map(ServerEvent.executionEnded)
    case "session.execution.interrupted":
      // A steer interrupts the active step and immediately starts the next one; not settled.
      if data?.reason == "superseded" { return nil }
      return data?.sessionID.map(ServerEvent.executionEnded)
    case "session.created":
      return data?.sessionID.map { ServerEvent.sessionCreated(sessionID: $0, parentID: data?.parentID) }
    case "session.forked":
      // A fork is a new root: its `parentID` names the session it was copied from.
      return data?.sessionID.map { .sessionCreated(sessionID: $0, parentID: nil) }
    case "session.viewed":
      guard let id = data?.sessionID, let idle = data?.idle else { return nil }
      return .sessionViewChanged(sessionID: id, idle: Int64(idle))
    case "session.revert.staged":
      guard let id = data?.sessionID, let boundary = data?.revert?.messageID else { return nil }
      return .revertChanged(sessionID: id, messageID: boundary, committed: false)
    case "session.revert.cleared", "session.revert.committed":
      guard let id = data?.sessionID else { return nil }
      return .revertChanged(sessionID: id, messageID: nil, committed: type == "session.revert.committed")
    case "session.renamed":
      guard let id = data?.sessionID, let title = data?.title else { return nil }
      return .sessionRenamed(sessionID: id, title: title)
    case "session.moved":
      guard let id = data?.sessionID else { return nil }
      guard let directory = data?.location?.value?.directory else {
        return .messageInvalidated(sessionID: id)
      }
      return .sessionMoved(sessionID: id, directory: directory)
    case "session.deleted":
      return data?.sessionID.map(ServerEvent.sessionDeleted)
    case "session.archived", "session.unarchived":
      return data?.sessionID.map {
        .sessionArchiveChanged(sessionID: $0, isArchived: type == "session.archived")
      }
    case "project.updated":
      guard let id = data?.id, let canonical = data?.canonical else { return nil }
      let payload = ProjectPayload(
        id: id,
        canonical: canonical,
        name: data?.name,
        repository: data?.repository,
        icon: data?.icon
      )
      return .projectUpdated(payload.project)
    case "model.updated", "provider.updated":
      return .modelsChanged
    case "agent.updated":
      return .agentsChanged
    case "session.inbox.cancelled":
      guard let id = data?.sessionID, let inputID = data?.inboxID else { return nil }
      return .inputCancelled(sessionID: id, inputID: inputID)
    case "session.inbox.enqueued", "session.inbox.delivery.changed":
      guard let id = data?.sessionID else { return nil }
      return .inputEnqueued(sessionID: id, inputID: data?.inboxID)
    case "session.inbox.delivered":
      return data?.sessionID.map { .inputQueueChanged(sessionID: $0, inputID: data?.inboxID) }
    case "session.step.started":
      return content { .stepStarted(messageID: $0) }
    case "session.step.streamed":
      return content { .stepStreamed(messageID: $0) }
    case "session.step.ended", "session.step.failed":
      return content { .stepEnded(messageID: $0) }
    case "session.text.started":
      return ordinalContent { .textStarted(messageID: $0, ordinal: $1) }
    case "session.text.delta":
      guard let delta = data?.delta else { return nil }
      return ordinalContent {
        .textDelta(messageID: $0, ordinal: $1, delta: delta, accumulatedText: nil)
      }
    case "session.text.ended":
      guard let text = data?.text else { return nil }
      return ordinalContent { .textEnded(messageID: $0, ordinal: $1, text: text) }
    case "session.reasoning.started":
      return ordinalContent { .reasoningStarted(messageID: $0, ordinal: $1) }
    case "session.reasoning.delta":
      return ordinalContent { .reasoningDelta(messageID: $0, ordinal: $1) }
    case "session.reasoning.ended":
      return ordinalContent { .reasoningEnded(messageID: $0, ordinal: $1) }
    case "session.tool.input.started":
      guard let name = data?.name else { return nil }
      return toolContent { messageID, toolID, _ in
        .toolInputStarted(messageID: messageID, toolID: toolID, name: name)
      }
    case "session.tool.input.delta":
      return toolContent {
        .toolInputDelta(messageID: $0, toolID: $1, delta: $2.delta ?? "")
      }
    case "session.tool.input.ended":
      return toolContent {
        .toolInputEnded(messageID: $0, toolID: $1, text: $2.text ?? "")
      }
    case "session.tool.called":
      return toolContent {
        .toolCalled(messageID: $0, toolID: $1, input: $2.input ?? .object([:]))
      }
    case "session.tool.progress":
      return toolContent {
        .toolProgress(messageID: $0, toolID: $1, metadata: $2.metadata ?? [:])
      }
    case "session.tool.success":
      return toolContent {
        .toolSucceeded(
          messageID: $0,
          toolID: $1,
          output: $2.textOutput,
          metadata: $2.metadata ?? [:]
        )
      }
    case "session.tool.failed":
      return toolContent {
        .toolFailed(
          messageID: $0,
          toolID: $1,
          error: $2.error?.message ?? ServerCopy.toolFailed,
          errorType: $2.error?.type,
          output: $2.textOutput,
          metadata: $2.metadata ?? [:]
        )
      }
    case "session.message.content.updated", "session.synthetic", "session.instructions.updated",
      "session.agent.selected", "session.model.selected", "session.permissions",
      "session.retry.scheduled", "session.compaction.started",
      "session.compaction.ended", "session.compaction.failed", "session.shell.started",
      "session.shell.ended":
      return data?.sessionID.map(ServerEvent.messageInvalidated)
    case "permission.asked", "form.created":
      guard let id = data?.sessionID ?? data?.form?.sessionID else { return nil }
      return id == "global" ? nil : .attentionChanged(askedSessionID: id)
    case "permission.replied", "form.replied", "form.cancelled":
      return data?.sessionID != nil ? .attentionChanged(askedSessionID: nil) : nil
    case "shell.created":
      guard let info = data?.info, info.status == "running" else { return nil }
      return .shellStarted(info.shell(isListed: false))
    case "shell.exited", "shell.deleted":
      return data?.id.map { .shellEnded(shellID: $0) }
    default:
      return nil
    }
  }
}
