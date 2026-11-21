import Foundation

/// A running server shell (`Shell.Info`). `metadata.sessionID` names the owner.
public struct ServerShell: Sendable, Equatable {
  public var id: String
  public var command: String
  public var sessionID: String?
  /// User `!` commands are created with `metadata.background`.
  public var isUserCommand: Bool
  /// Read from `GET /api/shell` rather than observed starting live.
  public var isListed: Bool
  public var status: Status
  /// Set once the command exits on its own.
  public var exitCode: Int?
  public var startedAt: Date?
  public var completedAt: Date?

  public enum Status: String, Sendable, Equatable, CaseIterable {
    case running
    case exited
    case timeout
    case killed
  }

  public init(
    id: String,
    command: String,
    sessionID: String? = nil,
    isUserCommand: Bool = false,
    isListed: Bool = false,
    status: Status = .running,
    exitCode: Int? = nil,
    startedAt: Date? = nil,
    completedAt: Date? = nil
  ) {
    self.id = id
    self.command = command
    self.sessionID = sessionID
    self.isUserCommand = isUserCommand
    self.isListed = isListed
    self.status = status
    self.exitCode = exitCode
    self.startedAt = startedAt
    self.completedAt = completedAt
  }

  public var title: String {
    command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
  }
}

/// `Shell.Info` on the wire.
public struct ShellInfoPayload: Codable, Sendable {
  public var id: String
  public var status: String
  public var command: String
  public var metadata: [String: JSONValue]?
  public var exit: Double?
  public var time: Time?

  public struct Time: Codable, Sendable {
    public var started: Double?
    public var completed: Double?

    public init(started: Double? = nil, completed: Double? = nil) {
      self.started = started
      self.completed = completed
    }
  }

  public init(
    id: String,
    status: String,
    command: String,
    metadata: [String: JSONValue]? = nil,
    exit: Double? = nil,
    time: Time? = nil
  ) {
    self.id = id
    self.status = status
    self.command = command
    self.metadata = metadata
    self.exit = exit
    self.time = time
  }

  public func shell(isListed: Bool) -> ServerShell {
    ServerShell(
      id: id,
      command: command,
      sessionID: metadata?["sessionID"]?.stringValue,
      isUserCommand: metadata?["background"]?.boolValue == true,
      isListed: isListed,
      // An unknown future status still reads as finished, never as running.
      status: ServerShell.Status(rawValue: status) ?? .exited,
      exitCode: exit.map { Int($0) },
      startedAt: time?.started.map(ServerDate.milliseconds),
      completedAt: time?.completed.map(ServerDate.milliseconds)
    )
  }
}

/// A background job (`Job.Info`, experimental). A subagent job's work runs in `childSessionID`.
public struct ServerJob: Sendable, Equatable {
  public var id: String
  public var kind: Kind
  public var sessionID: String
  public var isRunning: Bool
  public var childSessionID: String?
  public var startedAt: Date?

  public enum Kind: String, Sendable, Equatable, CaseIterable {
    case shell
    case subagent
    case image
    case video
    case codemode
    case unknown = ""

    public static func of(_ raw: String) -> Kind {
      Kind(rawValue: raw) ?? .unknown
    }
  }

  public init(
    id: String,
    kind: Kind,
    sessionID: String,
    isRunning: Bool,
    childSessionID: String? = nil,
    startedAt: Date? = nil
  ) {
    self.id = id
    self.kind = kind
    self.sessionID = sessionID
    self.isRunning = isRunning
    self.childSessionID = childSessionID
    self.startedAt = startedAt
  }

  /// The session whose tree the work keeps busy.
  public var ownerSessionID: String {
    kind == .subagent ? (childSessionID ?? sessionID) : sessionID
  }
}

/// `Job.Info` on the wire: only the fields the background-work capsule reads.
public struct JobInfoPayload: Codable, Sendable {
  public var id: String
  public var kind: String
  public var sessionID: String
  public var status: String
  public var childSessionID: String?
  public var time: Time?

  public struct Time: Codable, Sendable {
    public var started: Double?

    public init(started: Double? = nil) {
      self.started = started
    }
  }

  public init(
    id: String,
    kind: String,
    sessionID: String,
    status: String,
    childSessionID: String? = nil,
    time: Time? = nil
  ) {
    self.id = id
    self.kind = kind
    self.sessionID = sessionID
    self.status = status
    self.childSessionID = childSessionID
    self.time = time
  }

  public var job: ServerJob {
    ServerJob(
      id: id,
      kind: ServerJob.Kind.of(kind),
      sessionID: sessionID,
      isRunning: status == "running",
      childSessionID: childSessionID,
      startedAt: time?.started.map(ServerDate.milliseconds)
    )
  }
}

/// Epoch milliseconds as a `Date`, keeping sub-millisecond precision.
public enum ServerDate {
  public static func milliseconds(_ value: Double) -> Date {
    let seconds = (value / 1000).rounded(.down)
    let nanos = (value - seconds * 1000) * 1_000_000
    return Date(timeIntervalSince1970: seconds + nanos / 1_000_000_000)
  }
}
