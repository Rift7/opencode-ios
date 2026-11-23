import Foundation
import OpenCodeServer
import OpenCodeTranscript

/// The earlier-history cursor chain. `unknownEdge` reads the newest window once to find the
/// overlap before walking back; a page that does not overlap seeks again from its own cursor.
public enum TranscriptEarlierHistory: Equatable, Sendable {
  case unknownEdge
  case seekingOverlap(cursor: String?)
  case paging(cursor: String?)
  case loading(cursor: String?, reachedLoadedItems: Bool)
  case exhausted
}

/// One session's transcript. Items are oldest first. Read and view state share this value so a
/// covered subagent page comes back with its disclosures, position and loaded history intact.
public struct TranscriptState: Equatable, Sendable {
  public static let initialLimit = 30
  public static let historyPageLimit = 80
  public static let baseVisibleLimit = 20
  public static let settledWindowEntries = 45
  public static let settledWindowCap = 120

  public var sessionID: String
  public var items: [TranscriptItem]
  /// Bumped when an authoritative window invalidates the older-cursor chain. Late pages compare it.
  public var generation: Int
  public var earlier: TranscriptEarlierHistory
  public var insertionAnchorID: String?
  public var initialLoaded: Bool
  public var problem: SessionProblem?
  public var earlierProblem: SessionProblem?
  public var expandedIDs: Set<String>
  public var scrollAnchorID: String?
  public var isFollowing: Bool
  public var showsJumpToLatest: Bool
  /// Set once a newest window has been applied; the empty state waits for it.
  public var didApplyWindow: Bool

  public init(
    sessionID: String,
    items: [TranscriptItem] = [],
    generation: Int = 0,
    earlier: TranscriptEarlierHistory = .unknownEdge,
    insertionAnchorID: String? = nil,
    initialLoaded: Bool = false,
    problem: SessionProblem? = nil,
    earlierProblem: SessionProblem? = nil,
    expandedIDs: Set<String> = [],
    scrollAnchorID: String? = nil,
    isFollowing: Bool = true,
    showsJumpToLatest: Bool = false,
    didApplyWindow: Bool = false
  ) {
    self.sessionID = sessionID
    self.items = items
    self.generation = generation
    self.earlier = earlier
    self.insertionAnchorID = insertionAnchorID
    self.initialLoaded = initialLoaded
    self.problem = problem
    self.earlierProblem = earlierProblem
    self.expandedIDs = expandedIDs
    self.scrollAnchorID = scrollAnchorID
    self.isFollowing = isFollowing
    self.showsJumpToLatest = showsJumpToLatest
    self.didApplyWindow = didApplyWindow
  }

  public var isLoadingEarlier: Bool {
    if case .loading = earlier { return true }
    return false
  }

  public var hasEarlierItems: Bool { earlier != .exhausted }

  public var canLoadEarlier: Bool { hasEarlierItems && !isLoadingEarlier }

  public var isLoadingInitial: Bool { !didApplyWindow && problem == nil }

  public var showsEmptyState: Bool {
    didApplyWindow && items.isEmpty && earlier == .exhausted && problem == nil && !isLoadingEarlier
  }

  public var entries: [TranscriptEntry] {
    TranscriptGrouping.build(items: items)
  }

  public func entries(isRunning: Bool) -> [TranscriptEntry] {
    TranscriptGrouping.build(items: items, isRunning: isRunning)
  }

  public func isExpanded(_ id: String) -> Bool { expandedIDs.contains(id) }

  /// The rows a first paint shows. Loaded pages stay loaded; the view lazily draws them.
  public var visibleEntries: [TranscriptEntry] {
    Array(TranscriptGrouping.window(entries, limit: max(Self.baseVisibleLimit, items.count)))
  }

  public var copyableReplyText: [String: String] {
    var texts: [String: String] = [:]
    for entry in entries {
      if case .replyEnd(_, let reply) = entry {
        texts[entry.id] = reply.joined(separator: "\n\n")
      }
    }
    return texts
  }

  public func copyText(for entryID: String) -> String? {
    copyableReplyText[entryID]
  }
}
