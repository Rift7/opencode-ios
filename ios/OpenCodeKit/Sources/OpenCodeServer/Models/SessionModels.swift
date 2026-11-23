import Foundation

/// What opening a session means. The destination is P7's; a selection always carries the server it
/// belongs to so a stale selection cannot open a session on another server.
public struct SessionSelection: Equatable, Sendable, Identifiable {
  public enum Intent: Equatable, Sendable {
    /// The person picked the row.
    case browse
    /// The person opened the open Catch Up card, which must not mark it read.
    case catchUpCard
    /// A What's New prompt, typed into a new session but never sent.
    case whatsNewDraft(prompt: String)
    /// An empty new-session screen. `sessionID` is the client-made ID the first send creates with.
    case newSession(directory: String)
  }

  public var serverID: String
  public var sessionID: String
  public var intent: Intent

  public init(serverID: String, sessionID: String, intent: Intent) {
    self.serverID = serverID
    self.sessionID = sessionID
    self.intent = intent
  }

  public var id: String {
    let suffix: String
    switch intent {
    case .browse: suffix = "browse"
    case .catchUpCard: suffix = "catch-up"
    case .whatsNewDraft(let prompt): suffix = "draft:\(prompt)"
    case .newSession(let directory): suffix = "new:\(directory)"
    }
    return "\(serverID)|\(sessionID)|\(suffix)"
  }
}


/// A root session and every subagent below it, plus the IDs running right now.
public struct SessionFamily: Equatable, Sendable {
  public var root: OpenCodeSession
  public var sessions: [OpenCodeSession]
  public var activeSessionIDs: Set<String>

  public init(
    root: OpenCodeSession,
    sessions: [OpenCodeSession],
    activeSessionIDs: Set<String> = []
  ) {
    self.root = root
    self.sessions = sessions
    self.activeSessionIDs = activeSessionIDs
  }

  public func session(_ id: String) -> OpenCodeSession? {
    sessions.first { $0.id == id }
  }

  /// Depth-first order under the root, parents before children, siblings newest first.
  public var subagents: [OpenCodeSession] {
    var children: [String: [OpenCodeSession]] = [:]
    for session in sessions where session.id != root.id {
      let parent = session.parentID ?? root.id
      children[parent, default: []].append(session)
    }
    for key in children.keys {
      children[key]?.sort { $0.updatedAt > $1.updatedAt }
    }
    var ordered: [OpenCodeSession] = []
    var queue = [root.id]
    var visited = Set([root.id])
    var index = 0
    while index < queue.count {
      let parent = queue[index]
      index += 1
      for child in children[parent] ?? [] where visited.insert(child.id).inserted {
        ordered.append(child)
        queue.append(child.id)
      }
    }
    return ordered
  }

  public func isActive(_ id: String) -> Bool { activeSessionIDs.contains(id) }
}

/// One page of a shell's captured combined output. Cursors are absolute byte offsets.
public struct ShellOutputPage: Equatable, Sendable, Codable {
  public var output: String
  public var cursor: Int
  public var size: Int

  public init(output: String, cursor: Int, size: Int) {
    self.output = output
    self.cursor = cursor
    self.size = size
  }
}

/// `POST /api/session/{id}/interrupt`: whether a run was stopped.
public struct InterruptResult: Equatable, Sendable, Codable {
  public var interrupted: Bool

  public init(interrupted: Bool) {
    self.interrupted = interrupted
  }
}
