import Foundation
import OpenCodeCore
import OpenCodeServer

/// Where a composer's draft belongs. A new-session draft is scoped by its project so leaving and
/// returning to the same project restores it; once the first send creates the session it moves to
/// that session's key.
public enum ComposerScope: Codable, Hashable, Sendable {
  case session(String)
  case newSession(directory: String)

  public var storageToken: String {
    switch self {
    case .session(let id): "session:\(id)"
    case .newSession(let directory): "new:\(directory)"
    }
  }
}

public struct ComposerDraftKey: Codable, Hashable, Sendable {
  public var serverID: String
  public var scope: ComposerScope

  public init(serverID: String, scope: ComposerScope) {
    self.serverID = serverID
    self.scope = scope
  }

  public var storageKey: String { "\(serverID)|\(scope.storageToken)" }
}

/// One transcript quote waiting to be sent. The wire form is a `metadata.comments` entry plus a
/// quoted block in the model text; the transcript itself renders the same pair.
public struct ComposerQuote: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var text: String
  public var comment: String?

  public init(id: String = UUID().uuidString.lowercased(), text: String, comment: String? = nil) {
    self.id = id
    self.text = text
    self.comment = comment
  }

  /// Selection text with surrounding whitespace removed; nil when nothing is left.
  public static func cleaned(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  public var wire: TranscriptQuote {
    TranscriptQuote(text: text, comment: comment?.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

/// The composer's destination. `newSession.id` is the client-made session ID used for the first
/// create, so a retry cannot create a second session.
public enum ComposerTarget: Codable, Equatable, Hashable, Sendable {
  case session(id: String)
  case newSession(id: String, directory: String)

  public var sessionID: String? {
    if case .session(let id) = self { return id }
    return nil
  }

  public var directory: String? {
    if case .newSession(_, let directory) = self { return directory }
    return nil
  }

  public var isNewSession: Bool {
    if case .newSession = self { return true }
    return false
  }

  public var newSessionID: String? {
    if case .newSession(let id, _) = self { return id }
    return nil
  }

  public var scope: ComposerScope {
    switch self {
    case .session(let id): .session(id)
    case .newSession(_, let directory): .newSession(directory: directory)
    }
  }
}

/// The persisted part of a composer. Selection and focus are view state and deliberately absent.
public struct ComposerDraft: Codable, Equatable, Sendable {
  public var text: String
  public var quotes: [ComposerQuote]
  public var projectDirectory: String?
  /// A first send created this session, but the send or the app stopped before the screen learned.
  public var createdSessionID: String?
  /// Failed sends remain owned by this composer until Retry, Edit or Delete.
  public var failedSends: [FailedComposerSend]
  /// An admitted or possibly admitted send whose outcome is not settled. At most one is in flight.
  public var outbound: [ComposerOutbound]
  /// Monotonic content revision. A late transfer or migration may not replace a newer record.
  public var revision: Int
  public var updatedAt: Date

  public init(
    text: String = "",
    quotes: [ComposerQuote] = [],
    projectDirectory: String? = nil,
    createdSessionID: String? = nil,
    failedSends: [FailedComposerSend] = [],
    outbound: [ComposerOutbound] = [],
    revision: Int = 0,
    updatedAt: Date = Date(timeIntervalSince1970: 0)
  ) {
    self.text = text
    self.quotes = quotes
    self.projectDirectory = projectDirectory
    self.createdSessionID = createdSessionID
    self.failedSends = failedSends
    self.outbound = outbound
    self.revision = revision
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case text, quotes, projectDirectory, createdSessionID, failedSends, outbound, revision, updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    text = try container.decode(String.self, forKey: .text)
    quotes = try container.decodeIfPresent([ComposerQuote].self, forKey: .quotes) ?? []
    projectDirectory = try container.decodeIfPresent(String.self, forKey: .projectDirectory)
    createdSessionID = try container.decodeIfPresent(String.self, forKey: .createdSessionID)
    failedSends = try container.decodeIfPresent([FailedComposerSend].self, forKey: .failedSends) ?? []
    outbound = try container.decodeIfPresent([ComposerOutbound].self, forKey: .outbound) ?? []
    revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
      ?? Date(timeIntervalSince1970: 0)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(text, forKey: .text)
    try container.encode(quotes, forKey: .quotes)
    try container.encodeIfPresent(projectDirectory, forKey: .projectDirectory)
    try container.encodeIfPresent(createdSessionID, forKey: .createdSessionID)
    try container.encode(failedSends, forKey: .failedSends)
    try container.encode(outbound, forKey: .outbound)
    try container.encode(revision, forKey: .revision)
    try container.encode(updatedAt, forKey: .updatedAt)
  }

  /// Whether this record is at least as new as another. Timestamps decide across sessions whose
  /// per-target revisions restarted; the revision breaks ties for fixed-clock records.
  public func supersedes(_ other: ComposerDraft) -> Bool {
    if updatedAt != other.updatedAt { return updatedAt > other.updatedAt }
    return revision >= other.revision
  }

  /// Whether two snapshots would persist the same composer content. Timestamps and the revision
  /// itself are excluded so a flush can wait for content, not bookkeeping.
  public func sameContent(as other: ComposerDraft) -> Bool {
    text == other.text
      && quotes == other.quotes
      && projectDirectory == other.projectDirectory
      && createdSessionID == other.createdSessionID
      && failedSends == other.failedSends
      && outbound == other.outbound
  }

  public var isEmpty: Bool {
    text.isEmpty && quotes.isEmpty && createdSessionID == nil && failedSends.isEmpty
      && outbound.isEmpty
  }

  public func boundedProblem() -> ComposerDraftSave? {
    let outboundAndFailed = failedSends.map { ($0.text, $0.quotes) }
      + outbound.map { ($0.text, $0.quotes) }
    let textBytes = text.utf8.count
      + outboundAndFailed.reduce(0) { $0 + $1.0.utf8.count }
    let allQuotes = quotes + outboundAndFailed.flatMap { $0.1 }
    let quoteBytes = allQuotes.reduce(0) {
      $0 + $1.text.utf8.count + ($1.comment?.utf8.count ?? 0)
    }
    if textBytes > ComposerDraftBounds.maximumTextBytes {
      return .tooLarge
    }
    if quoteBytes > ComposerDraftBounds.maximumQuoteBytes
      || allQuotes.count > ComposerDraftBounds.maximumQuotes
    {
      return .tooLarge
    }
    return nil
  }
}

public enum ComposerDraftBounds {
  /// A draft larger than this is kept in memory and reported, never silently truncated.
  public static let maximumTextBytes = 128 * 1024
  public static let maximumQuoteBytes = 64 * 1024
  public static let maximumQuotes = 200
}

public enum ComposerDraftLoad: Equatable, Sendable {
  case found(ComposerDraft)
  case missing
  case failure(StorageFailure)
  /// A draft was found under the New Session key after its created session key was lost or the
  /// destination save failed. The migration outcome says whether cleanup is still pending.
  case foundFromSource(ComposerDraft, ComposerDraftMigration)
}

public enum ComposerDraftMigration: Equatable, Sendable {
  case migrated
  case destinationFailed(StorageFailure)
  case sourceRetained(StorageFailure)
}

public enum ComposerDraftSave: Equatable, Sendable {
  case saved
  case tooLarge
  case failure(StorageFailure)
}

/// Typed facts for the composer's error line. Copy is chosen at the view edge.
public enum ComposerProblem: String, Codable, Equatable, Sendable {
  case couldNotRestore
  case couldNotSave
  case couldNotCleanUpDraft
  case draftTooLarge
  case couldNotSend
  case couldNotVerifySend
  case notConnected
  case busy
  case requestPending
}

/// How a failed POST is treated. A definite rejection never reached the session's history; an
/// ambiguous outcome may have been accepted, so it must be read back before a retry.
public enum ComposerSendFailure: String, Codable, Equatable, Sendable {
  case definite
  case ambiguous

  public static func classify(_ error: OpenCodeClientError) -> ComposerSendFailure {
    if error.mayHaveReachedServer { return .ambiguous }
    if let status = error.statusCode {
      if status == 408 || status == 429 || status == 503 { return .ambiguous }
      if OpenCodeClientError.isGatewayFailure(status) { return .ambiguous }
      return .definite
    }
    return .ambiguous
  }
}

public struct FailedComposerSend: Codable, Identifiable, Equatable, Sendable {
  public var id: String { messageID }
  public var messageID: String
  public var text: String
  public var quotes: [ComposerQuote]
  public var delivery: Delivery
  public var target: ComposerTarget
  public var reason: ComposerProblem
  public var failure: ComposerSendFailure

  public init(
    messageID: String,
    text: String,
    quotes: [ComposerQuote],
    delivery: Delivery,
    target: ComposerTarget,
    reason: ComposerProblem,
    failure: ComposerSendFailure
  ) {
    self.messageID = messageID
    self.text = text
    self.quotes = quotes
    self.delivery = delivery
    self.target = target
    self.reason = reason
    self.failure = failure
  }

  public var send: ComposerSend {
    ComposerSend(
      target: target,
      messageID: messageID,
      text: text,
      quotes: quotes,
      delivery: delivery,
      revision: 0
    )
  }
}

/// A send owned by the composer from the tap until acceptance, confirmed failure or explicit
/// reconciliation. Persisted before dispatch so termination cannot strand the payload.
public struct ComposerOutbound: Codable, Identifiable, Equatable, Sendable {
  public var id: String { messageID }
  public var target: ComposerTarget
  public var messageID: String
  public var text: String
  public var quotes: [ComposerQuote]
  public var delivery: Delivery
  public var revision: Int
  public var createdAt: Date

  public init(
    target: ComposerTarget,
    messageID: String,
    text: String,
    quotes: [ComposerQuote],
    delivery: Delivery,
    revision: Int,
    createdAt: Date = Date(timeIntervalSince1970: 0)
  ) {
    self.target = target
    self.messageID = messageID
    self.text = text
    self.quotes = quotes
    self.delivery = delivery
    self.revision = revision
    self.createdAt = createdAt
  }

  public var send: ComposerSend {
    ComposerSend(
      target: target,
      messageID: messageID,
      text: text,
      quotes: quotes,
      delivery: delivery,
      revision: revision
    )
  }
}

/// The immutable request one tap of Send produced. Its message ID identifies the optimistic
/// transcript row and the idempotent prompt admission across retries and reconciliation.
public struct ComposerSend: Equatable, Sendable {
  public var target: ComposerTarget
  public var messageID: String
  public var text: String
  public var quotes: [ComposerQuote]
  public var delivery: Delivery
  public var revision: Int

  public init(
    target: ComposerTarget,
    messageID: String,
    text: String,
    quotes: [ComposerQuote],
    delivery: Delivery,
    revision: Int
  ) {
    self.target = target
    self.messageID = messageID
    self.text = text
    self.quotes = quotes
    self.delivery = delivery
    self.revision = revision
  }

  public var hasContent: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !quotes.isEmpty
  }

  /// The model-visible text and its metadata, using the audited quote contract: quoted lines in
  /// the prompt and `{"type":"quote"}` entries in `metadata.comments`.
  public var prompt: PromptBody {
    let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var parts: [String] = []
    if !typed.isEmpty { parts.append(typed) }
    for quote in quotes { parts.append(Self.quoteBlock(quote)) }
    let modelText = parts.joined(separator: "\n")
    let comments = quotes.compactMap { quote -> PromptBody.Metadata.Comment? in
      let comment = quote.comment?.trimmingCharacters(in: .whitespacesAndNewlines)
      return PromptBody.Metadata.Comment(
        type: "quote",
        text: quote.text,
        comment: (comment?.isEmpty ?? true) ? nil : comment
      )
    }
    let metadata = comments.isEmpty
      ? nil
      : PromptBody.Metadata(displayText: typed, comments: comments)
    return PromptBody(id: messageID, text: modelText, delivery: delivery, metadata: metadata)
  }

  public static func quoteBlock(_ quote: ComposerQuote) -> String {
    let lines = quote.text.split(separator: "\n", omittingEmptySubsequences: false)
      .map { "> \($0)" }
      .joined(separator: "\n")
    let block = "The user quoted the following from earlier in the conversation:\n\(lines)"
    let comment = quote.comment?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let comment, !comment.isEmpty else { return block }
    return "\(block)\n\nThe user made the following comment regarding this quote: \(comment)"
  }
}
