import Foundation

/// A model selection: the catalogue key, its provider, and an optional reasoning variant.
public struct ModelRef: Codable, Sendable, Equatable, Hashable {
  public var id: String
  public var providerID: String
  /// The reasoning variant (`high`, `max`, …); nil is the model's default.
  public var variant: String?

  public init(id: String, providerID: String, variant: String? = nil) {
    self.id = id
    self.providerID = providerID
    self.variant = variant
  }

  /// The same model, ignoring the variant.
  public func sameModel(as other: ModelRef) -> Bool {
    id == other.id && providerID == other.providerID
  }
}

/// Inbox delivery for a prompt sent while the session is running.
public enum Delivery: String, Codable, Sendable, Equatable, CaseIterable {
  case steer
  case queue

  /// The label the composer uses for a pending row.
  public var pendingLabel: String {
    switch self {
    case .steer: "Steering"
    case .queue: "Queued"
    }
  }
}

/// The prompt admission body. Absent files, delivery and metadata are omitted, so a plain prompt is
/// just `{"id","text"}`.
///
/// Only the fields this phase can build are modelled. Mention, quote, page and notification
/// metadata belong to the composer and notification phases, which extend this struct rather than
/// shaping JSON by hand.
public struct PromptBody: Codable, Sendable, Equatable {
  public var id: String
  public var text: String
  public var files: [File]?
  public var delivery: String?
  public var metadata: Metadata?

  public struct File: Codable, Sendable, Equatable {
    public var uri: String
    public var name: String?

    public init(uri: String, name: String? = nil) {
      self.uri = uri
      self.name = name
    }
  }

  public struct Metadata: Codable, Sendable, Equatable {
    public var displayText: String?
    /// The desktop only reads `displayText` when `comments` is an array.
    public var comments: [Comment]?
    public var attachments: [Attachment]?

    public struct Comment: Codable, Sendable, Equatable {
      public var type: String
      public var text: String
      public var comment: String?

      public init(type: String, text: String, comment: String? = nil) {
        self.type = type
        self.text = text
        self.comment = comment
      }
    }

    public struct Attachment: Codable, Sendable, Equatable {
      public var name: String
      public var mime: String
      public var path: String

      public init(name: String, mime: String, path: String) {
        self.name = name
        self.mime = mime
        self.path = path
      }
    }

    public init(displayText: String? = nil, comments: [Comment]? = nil, attachments: [Attachment]? = nil) {
      self.displayText = displayText
      self.comments = comments
      self.attachments = attachments
    }
  }

  public init(
    id: String,
    text: String,
    files: [File]? = nil,
    delivery: Delivery? = nil,
    metadata: Metadata? = nil
  ) {
    self.id = id
    self.text = text
    self.files = files
    self.delivery = delivery?.rawValue
    self.metadata = metadata
  }

  /// A prompt with nothing but text, the shape every plain send uses.
  public static func plain(id: String, text: String, delivery: Delivery? = nil) -> PromptBody {
    PromptBody(id: id, text: text, delivery: delivery)
  }
}
