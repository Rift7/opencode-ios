import Foundation

/// The one rule for what a session is called, used by every surface.
///
/// A real server title always wins. Until the server names a session it reads as its first prompt on
/// one line; only when nothing is known does it read "Untitled session". V2 omits `Session.Info.title`
/// for an unnamed session, so `placeholder` is what this app stores then and what older snapshots
/// hold; both count as no title.
public enum SessionTitle {
  /// Stored data for an unnamed session, so it stays English.
  public static let placeholder = "Untitled session"

  /// The most characters a first-prompt title keeps before the ellipsis.
  public static let previewLimit = 60
  private static let wordBoundaryMinimum = 40
  private static let trailingPunctuation = Set(".,;:!?-–—")

  public static func display(serverTitle: String?, firstPrompt: String?) -> String {
    let title = trimmed(serverTitle) ?? ""
    if !isPlaceholder(title) { return title }
    if let preview = trimmed(firstPrompt) { return preview }
    return placeholder
  }

  public static func isPlaceholder(_ title: String?) -> Bool {
    let value = trimmed(title) ?? ""
    return value.isEmpty || value.caseInsensitiveCompare(placeholder) == .orderedSame
  }

  /// `text` on one line: whitespace and newlines collapse to single spaces, and past `previewLimit`
  /// characters it is cut at a nearby word boundary (else mid-word) and gets an ellipsis.
  public static func preview(_ text: String) -> String? {
    let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !line.isEmpty else { return nil }
    guard line.count > previewLimit else { return line }
    var end = line.index(line.startIndex, offsetBy: previewLimit)
    if let space = line[..<end].lastIndex(of: " "),
      line.distance(from: line.startIndex, to: space) >= wordBoundaryMinimum
    {
      end = space
    }
    let cut = line[..<end].reversed().drop { $0.isWhitespace || trailingPunctuation.contains($0) }.reversed()
    return String(cut) + "…"
  }

  private static func trimmed(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// A session as the server describes it.
public struct OpenCodeSession: Sendable, Equatable, Codable {
  public var id: String
  /// `Session.Info.title`; the server leaves it blank until the session is named.
  public var serverTitle: String
  public var projectID: String
  public var directory: String
  public var updatedAt: Date
  /// Int64 epoch milliseconds, echoed to `/view`.
  public var idleMilliseconds: Int64?
  public var viewedMilliseconds: Int64?
  public var model: ModelRef?
  public var parentID: String?
  public var agent: String?
  /// Spend in USD for this session alone.
  public var cost: Double?
  /// Always Notify (`metadata.notification.always`).
  public var alwaysNotify: Bool
  /// A staged undo: this message and everything after it are hidden.
  public var revertMessageID: String?
  /// The session's first prompt as a one-line preview, once known.
  public var firstPrompt: String?
  /// When the session was archived; nil while it isn't.
  public var archivedAt: Date?

  public init(
    id: String,
    serverTitle: String = "",
    projectID: String,
    directory: String,
    updatedAt: Date,
    idleMilliseconds: Int64? = nil,
    viewedMilliseconds: Int64? = nil,
    model: ModelRef? = nil,
    parentID: String? = nil,
    agent: String? = nil,
    cost: Double? = nil,
    alwaysNotify: Bool = false,
    revertMessageID: String? = nil,
    firstPrompt: String? = nil,
    archivedAt: Date? = nil
  ) {
    self.id = id
    self.serverTitle = serverTitle
    self.projectID = projectID
    self.directory = directory
    self.updatedAt = updatedAt
    self.idleMilliseconds = idleMilliseconds
    self.viewedMilliseconds = viewedMilliseconds
    self.model = model
    self.parentID = parentID
    self.agent = agent
    self.cost = cost
    self.alwaysNotify = alwaysNotify
    self.revertMessageID = revertMessageID
    self.firstPrompt = firstPrompt
    self.archivedAt = archivedAt
  }

  /// What every surface calls this session: the server's title, else its first prompt.
  public var title: String {
    SessionTitle.display(serverTitle: serverTitle, firstPrompt: firstPrompt)
  }

  /// Archived sessions stay out of Recents, search, Catch Up and the system lists.
  public var isArchived: Bool { archivedAt != nil }
}

/// `{id, projectID, title?, time, location, model?, parentID?, agent?, cost?, metadata?, revert?}`.
public struct SessionPayload: Codable, Sendable {
  public var id: String
  public var projectID: String
  public var title: String?
  public var time: Time
  public var location: Location
  public var model: ModelRef?
  public var parentID: String?
  public var agent: String?
  public var cost: Double?
  public var metadata: SessionMetadata?
  public var revert: Revert?

  public struct Time: Codable, Sendable {
    /// Unix milliseconds as a JSON number.
    public var updated: Double
    public var idle: Int64?
    public var viewed: Int64?
    /// Set (epoch milliseconds) while the session is archived.
    public var archived: Double?

    public init(updated: Double, idle: Int64? = nil, viewed: Int64? = nil, archived: Double? = nil) {
      self.updated = updated
      self.idle = idle
      self.viewed = viewed
      self.archived = archived
    }
  }

  public struct Location: Codable, Sendable {
    public var directory: String

    public init(directory: String) {
      self.directory = directory
    }
  }

  public struct Revert: Codable, Sendable {
    public var messageID: String

    public init(messageID: String) {
      self.messageID = messageID
    }
  }

  /// Only `metadata.notification.always` matters; anything else decodes as off.
  public struct SessionMetadata: Codable, Sendable {
    public var alwaysNotify: Bool

    public init(alwaysNotify: Bool) {
      self.alwaysNotify = alwaysNotify
    }

    public init(from decoder: any Decoder) throws {
      let value = try JSONValue(from: decoder)
      alwaysNotify = value["notification"]?["always"]?.boolValue ?? false
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(JSONValue.null)
    }
  }

  public init(
    id: String,
    projectID: String,
    title: String? = nil,
    time: Time,
    location: Location,
    model: ModelRef? = nil,
    parentID: String? = nil,
    agent: String? = nil,
    cost: Double? = nil,
    metadata: SessionMetadata? = nil,
    revert: Revert? = nil
  ) {
    self.id = id
    self.projectID = projectID
    self.title = title
    self.time = time
    self.location = location
    self.model = model
    self.parentID = parentID
    self.agent = agent
    self.cost = cost
    self.metadata = metadata
    self.revert = revert
  }

  /// The model value: one timestamp is kept in both forms, so a caller picks the right one.
  public var updatedAt: Date {
    Date(timeIntervalSince1970: time.updated / 1000)
  }

  public var session: OpenCodeSession {
    OpenCodeSession(
      id: id,
      serverTitle: title ?? "",
      projectID: projectID,
      directory: location.directory,
      updatedAt: updatedAt,
      idleMilliseconds: time.idle,
      viewedMilliseconds: time.viewed,
      model: model,
      parentID: parentID,
      agent: agent,
      cost: cost,
      alwaysNotify: metadata?.alwaysNotify ?? false,
      revertMessageID: revert?.messageID,
      archivedAt: time.archived.map { Date(timeIntervalSince1970: $0 / 1000) }
    )
  }
}

/// `{data: [...], cursor?}` from `GET /api/session`.
public struct SessionsPayload: Codable, Sendable {
  public var data: [SessionPayload]
  public var cursor: CursorPayload?

  public init(data: [SessionPayload], cursor: CursorPayload? = nil) {
    self.data = data
    self.cursor = cursor
  }
}

/// `{data: { "<sessionID>": {type} }}` from `GET /api/session/active`.
public struct ActiveSession: Codable, Sendable, Equatable {
  public var type: String

  public init(type: String) {
    self.type = type
  }
}

/// One page of root sessions and the cursor of the next page.
public struct SessionPage: Sendable, Equatable {
  public var sessions: [OpenCodeSession]
  public var next: String?

  public init(sessions: [OpenCodeSession], next: String? = nil) {
    self.sessions = sessions
    self.next = next
  }
}

/// What a session page asks for: the newest root page, a search, or the page after one already read.
public enum SessionPageRequest: Sendable, Equatable {
  case first
  case search(String)
  case after(String)
}
