import Foundation

/// One semantic event from `GET /api/event`.
public enum ServerEvent: Sendable, Equatable {
  case connected
  case executionStarted(sessionID: String)
  case executionEnded(sessionID: String)
  /// `parentID` is set for a subagent: its family parent, which never changes.
  case sessionCreated(sessionID: String, parentID: String?)
  case sessionRenamed(sessionID: String, title: String)
  /// The session now lives in `directory` (Move to, or the server reviving one whose folder is gone).
  case sessionMoved(sessionID: String, directory: String)
  /// Another client (or this one) read a session up to `idle`.
  case sessionViewChanged(sessionID: String, idle: Int64)
  case sessionDeleted(sessionID: String)
  case sessionArchiveChanged(sessionID: String, isArchived: Bool)
  /// A delivery: `inputID` moved from the inbox into history.
  case inputQueueChanged(sessionID: String, inputID: String?)
  /// A message was admitted to the inbox. The audited client also carries the decoded row; the
  /// inbox model arrives with the session phase, so this carries its identity for now.
  case inputEnqueued(sessionID: String, inputID: String?)
  case inputCancelled(sessionID: String, inputID: String)
  /// A bounded, ordered projection batch: `EventBatcher` coalesces noisy deltas first.
  case contentBatch(sessionID: String, events: [LiveContentEvent])
  /// A durable event changed projected history in a way cheaper and safer to settle from REST.
  case messageInvalidated(sessionID: String)
  /// An undo was staged (`messageID`), redone (nil), or made final by a new prompt (`committed`).
  case revertChanged(sessionID: String, messageID: String?, committed: Bool)
  /// A pending request appeared or was settled. `askedSessionID` is set only for a fresh ask.
  case attentionChanged(askedSessionID: String?)
  /// Shell events are ephemeral; reconnects re-list running shells.
  case shellStarted(ServerShell)
  case shellEnded(shellID: String)
  /// A job started, moved to the background, or ended. Ephemeral; reconnects re-list running jobs.
  case jobUpdated(ServerJob)
  case projectUpdated(ServerProject)
  /// `model.updated` or `provider.updated`: the server's model catalog changed.
  case modelsChanged
  /// `agent.updated`: the server's agents changed.
  case agentsChanged

  /// The single session this event is scoped to, when ordering depends only on that session's
  /// pending deltas.
  public var targetSessionID: String? {
    switch self {
    case .executionStarted(let id), .executionEnded(let id), .sessionRenamed(let id, _),
      .sessionMoved(let id, _), .sessionViewChanged(let id, _), .sessionDeleted(let id),
      .sessionArchiveChanged(let id, _), .inputQueueChanged(let id, _), .inputEnqueued(let id, _),
      .inputCancelled(let id, _), .contentBatch(let id, _), .messageInvalidated(let id),
      .revertChanged(let id, _, _):
      return id
    case .shellStarted(let shell):
      return shell.sessionID
    case .connected, .sessionCreated, .attentionChanged, .shellEnded, .jobUpdated, .projectUpdated,
      .modelsChanged, .agentsChanged:
      return nil
    }
  }
}

/// A content event, ordered relative to the batch that carries it.
public enum LiveContentEvent: Sendable, Equatable {
  case stepStarted(messageID: String)
  case stepStreamed(messageID: String)
  case stepEnded(messageID: String)
  case textStarted(messageID: String, ordinal: Int)
  case textDelta(messageID: String, ordinal: Int, delta: String, accumulatedText: String?)
  case textEnded(messageID: String, ordinal: Int, text: String)
  case reasoningStarted(messageID: String, ordinal: Int)
  case reasoningDelta(messageID: String, ordinal: Int)
  case reasoningEnded(messageID: String, ordinal: Int)
  case toolInputStarted(messageID: String, toolID: String, name: String)
  case toolInputDelta(messageID: String, toolID: String, delta: String)
  case toolInputEnded(messageID: String, toolID: String, text: String)
  case toolCalled(messageID: String, toolID: String, input: JSONValue)
  case toolProgress(messageID: String, toolID: String, metadata: [String: JSONValue])
  case toolSucceeded(messageID: String, toolID: String, output: [String], metadata: [String: JSONValue])
  case toolFailed(
    messageID: String,
    toolID: String,
    error: String,
    errorType: String?,
    output: [String],
    metadata: [String: JSONValue]
  )

  public var messageID: String {
    switch self {
    case .stepStarted(let id), .stepStreamed(let id), .stepEnded(let id):
      return id
    case .textStarted(let id, _), .textDelta(let id, _, _, _), .textEnded(let id, _, _),
      .reasoningStarted(let id, _), .reasoningDelta(let id, _), .reasoningEnded(let id, _),
      .toolInputStarted(let id, _, _), .toolInputDelta(let id, _, _), .toolInputEnded(let id, _, _),
      .toolCalled(let id, _, _), .toolProgress(let id, _, _), .toolSucceeded(let id, _, _, _),
      .toolFailed(let id, _, _, _, _, _):
      return id
    }
  }

  public var isDurableBoundary: Bool {
    switch self {
    case .stepEnded, .textEnded, .toolInputEnded, .toolCalled, .toolSucceeded, .toolFailed: true
    default: false
    }
  }

  public var isToolLifecycleEvent: Bool {
    switch self {
    case .toolInputStarted, .toolCalled, .toolSucceeded, .toolFailed: true
    default: false
    }
  }

  /// The same semantic part identity used by REST decoding and live upserts.
  public var transcriptItemID: String? {
    switch self {
    case .textStarted(let id, let ordinal), .textDelta(let id, let ordinal, _, _),
      .textEnded(let id, let ordinal, _):
      return "\(id)-text-\(ordinal)"
    case .toolInputStarted(let id, let toolID, _), .toolInputDelta(let id, let toolID, _),
      .toolInputEnded(let id, let toolID, _), .toolCalled(let id, let toolID, _),
      .toolProgress(let id, let toolID, _), .toolSucceeded(let id, let toolID, _, _),
      .toolFailed(let id, let toolID, _, _, _, _):
      return "\(id)-tool-\(toolID)"
    case .stepStarted, .stepStreamed, .stepEnded, .reasoningStarted, .reasoningDelta, .reasoningEnded:
      return nil
    }
  }

  public var projectsRows: Bool { transcriptItemID != nil }

  /// This event followed by `next` as a single delta, when both stream into the same part.
  public func appendingDelta(_ next: LiveContentEvent) -> LiveContentEvent? {
    switch (self, next) {
    case let (
      .textDelta(id, ordinal, delta, nil), .textDelta(nextID, nextOrdinal, nextDelta, nil)
    ) where id == nextID && ordinal == nextOrdinal:
      return .textDelta(messageID: id, ordinal: ordinal, delta: delta + nextDelta, accumulatedText: nil)
    case (.reasoningDelta, .reasoningDelta):
      return self
    case let (.toolInputDelta(id, toolID, delta), .toolInputDelta(nextID, nextToolID, nextDelta))
      where id == nextID && toolID == nextToolID:
      return .toolInputDelta(messageID: id, toolID: toolID, delta: delta + nextDelta)
    default:
      return nil
    }
  }
}

extension Array where Element == LiveContentEvent {
  /// Consecutive deltas for the same part merge into one event, so a burst of tokens re-parses its
  /// row once. Only adjacent events merge; ordering relative to every other event is unchanged.
  public mutating func appendCoalescingDeltas(_ events: [LiveContentEvent]) {
    for event in events {
      if let merged = last?.appendingDelta(event) {
        self[self.count - 1] = merged
      } else {
        append(event)
      }
    }
  }
}
