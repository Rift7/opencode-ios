import ComposableArchitecture
import Foundation
import OpenCodeCore
import OpenCodeServer

/// The drawer row's dot. A waiting request wins over a running session, which wins over unread.
public enum DrawerIndicator: String, Equatable, Sendable {
  case attention
  case running
  case unread
  case none
}

/// Why the Home list could not be refreshed. Typed facts only; the view chooses copy.
public enum HomeFailure: Equatable, Sendable {
  case offline
  case unreachable
  case timedOut
  case credentialsRejected
  case incompatibleAPI(feature: String)
  case malformed(feature: String)
  case serverStatus(Int)
  case unsupported
  case unknown

  public static func from(_ error: OpenCodeClientError, isOffline: Bool = false) -> HomeFailure {
    switch error.failure {
    case .status(401):
      return .credentialsRejected
    case .status(let status):
      return .serverStatus(status)
    case .transport(let transport):
      switch transport {
      case .timedOut:
        return .timedOut
      case .notSent, .interrupted:
        return isOffline ? .offline : .unreachable
      }
    case .invalidURL, .unsupported:
      return .unsupported
    case .undecodable(let feature):
      return .malformed(feature: feature)
    case .responseTooLarge(let feature):
      return .malformed(feature: feature)
    case .incompatibleAPI(let feature):
      return .incompatibleAPI(feature: feature)
    case .unreachable:
      return isOffline ? .offline : .unreachable
    case .streamEnded, .streamServerFailure, .streamOversizedFrame:
      return .unknown
    case .streamOverflow:
      return .unknown
    case .pairingExpired, .pairingUnsupported:
      return .unsupported
    }
  }
}

/// A short, dismissible Home notice. Titles travel as data so the view localizes the sentence.
public enum HomeNotice: Equatable, Sendable {
  case couldNotRefresh(HomeFailure)
  case couldNotReadSnapshot(HomeSnapshotFailure)
  case couldNotSaveSnapshot(HomeSnapshotFailure)
  case couldNotDelete(title: String)
  case couldNotVerifyDeletion(title: String)
  case couldNotMarkRead(title: String)
  case couldNotLoadSearch
  case couldNotLoadOlder
}

/// What one REST read of the Home list returns. Projects come from the shell's authoritative
/// refresh, so a Home read only re-reads the session page and running set.
public struct HomeRefresh: Equatable, Sendable {
  public var sessions: [OpenCodeSession]
  public var next: String?
  public var activeSessionIDs: Set<String>

  public init(sessions: [OpenCodeSession], next: String?, activeSessionIDs: Set<String>) {
    self.sessions = sessions
    self.next = next
    self.activeSessionIDs = activeSessionIDs
  }
}

// MARK: - Snapshot persistence

/// One server's bounded Home snapshot. It is a read cache: REST stays authoritative, and a decode
/// failure is reported rather than trusted.
public struct HomeSnapshot: Codable, Equatable, Sendable {
  public static let currentVersion = 1
  public static let maximumServers = 8
  public static let maximumSessions = 50

  public var version: Int
  public var serverID: String
  public var projects: [ServerProject]
  public var sessions: [OpenCodeSession]
  public var activeSessionIDs: [String]
  public var nextCursor: String?
  public var capturedAt: Date

  public init(
    version: Int = HomeSnapshot.currentVersion,
    serverID: String,
    projects: [ServerProject],
    sessions: [OpenCodeSession],
    activeSessionIDs: Set<String>,
    nextCursor: String?,
    capturedAt: Date
  ) {
    self.version = version
    self.serverID = serverID
    self.projects = projects
    self.sessions = Array(sessions.prefix(HomeSnapshot.maximumSessions))
    self.activeSessionIDs = activeSessionIDs.sorted()
    self.nextCursor = nextCursor
    self.capturedAt = capturedAt
  }

  /// A snapshot for another build is not read, so a changed shape cannot be half-applied.
  public var isCurrent: Bool { version == Self.currentVersion }
}

/// What a targeted session read says about a deletion whose operation result was not definitive.
public enum DeletionVerification: Equatable, Sendable {
  case absent
  case present
  case inconclusive(OpenCodeClientError)
}

public enum HomeSnapshotFailure: Error, Equatable, Sendable {
  case unavailable
  case corrupt
  case encoding
  case other

  public init(_ failure: StorageFailure) {
    switch failure {
    case .unavailable: self = .unavailable
    case .denied: self = .unavailable
    case .encoding: self = .encoding
    case .other: self = .other
    }
  }
}

/// Reads and writes the per-server Home cache off the UI actor. Every operation reports an explicit
/// outcome; a missing file is not a failure.
public struct HomeSnapshotStore: Sendable {
  public var read: @Sendable (String) async -> Result<HomeSnapshot?, HomeSnapshotFailure>
  public var write: @Sendable (HomeSnapshot) async -> Result<Bool, HomeSnapshotFailure>
  public var remove: @Sendable (String) async -> Result<Void, HomeSnapshotFailure>

  public init(
    read: @escaping @Sendable (String) async -> Result<HomeSnapshot?, HomeSnapshotFailure>,
    write: @escaping @Sendable (HomeSnapshot) async -> Result<Bool, HomeSnapshotFailure>,
    remove: @escaping @Sendable (String) async -> Result<Void, HomeSnapshotFailure>
  ) {
    self.read = read
    self.write = write
    self.remove = remove
  }

  /// A fresh in-memory store per dependency resolution, for tests and previews.
  public static func inMemory() -> HomeSnapshotStore {
    let disk = InMemoryHomeSnapshots()
    return HomeSnapshotStore(
      read: { serverID in await disk.read(serverID) },
      write: { snapshot in await disk.write(snapshot) },
      remove: { serverID in await disk.remove(serverID) }
    )
  }
}

extension HomeSnapshotStore: DependencyKey {
  public static var liveValue: HomeSnapshotStore {
    let disk = HomeSnapshotDisk()
    return HomeSnapshotStore(
      read: { serverID in await disk.read(serverID) },
      write: { snapshot in await disk.write(snapshot) },
      remove: { serverID in await disk.remove(serverID) }
    )
  }

  public static var testValue: HomeSnapshotStore { .inMemory() }
}

extension DependencyValues {
  public var homeSnapshotStore: HomeSnapshotStore {
    get { self[HomeSnapshotStore.self] }
    set { self[HomeSnapshotStore.self] = newValue }
  }
}

private struct HomeSnapshotsPayload: Codable {
  var version: Int
  var entries: [HomeSnapshot]
}

/// The on-disk cache: one JSON file, versioned, bounded by server count and sessions per server.
private actor HomeSnapshotDisk {
  private let fileURL: URL?

  init(directory: URL? = nil) {
    let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    self.fileURL = base?.appendingPathComponent("home-snapshots.json", isDirectory: false)
  }

  func read(_ serverID: String) -> Result<HomeSnapshot?, HomeSnapshotFailure> {
    guard let fileURL else { return .failure(.unavailable) }
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return .success(nil) }
    do {
      let data = try Data(contentsOf: fileURL)
      let payload = try JSONDecoder().decode(HomeSnapshotsPayload.self, from: data)
      guard payload.version == HomeSnapshot.currentVersion else { return .failure(.corrupt) }
      return .success(payload.entries.first { $0.serverID == serverID && $0.isCurrent })
    } catch let error as HomeSnapshotFailure {
      return .failure(error)
    } catch {
      return .failure(.corrupt)
    }
  }

  func write(_ snapshot: HomeSnapshot) -> Result<Bool, HomeSnapshotFailure> {
    guard let fileURL else { return .failure(.unavailable) }
    guard snapshot.isCurrent else { return .failure(.encoding) }
    var entries: [HomeSnapshot] = []
    if let data = try? Data(contentsOf: fileURL),
      let payload = try? JSONDecoder().decode(HomeSnapshotsPayload.self, from: data),
      payload.version == HomeSnapshot.currentVersion
    {
      entries = payload.entries.filter { $0.serverID != snapshot.serverID && $0.isCurrent }
    }
    entries.insert(snapshot, at: 0)
    entries.sort { $0.capturedAt > $1.capturedAt }
    let payload = HomeSnapshotsPayload(
      version: HomeSnapshot.currentVersion,
      entries: Array(entries.prefix(HomeSnapshot.maximumServers))
    )
    do {
      let data = try JSONEncoder().encode(payload)
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: fileURL, options: .atomic)
      return .success(true)
    } catch let error as EncodingError {
      _ = error
      return .failure(.encoding)
    } catch {
      return .failure(.other)
    }
  }

  func remove(_ serverID: String) -> Result<Void, HomeSnapshotFailure> {
    guard let fileURL else { return .failure(.unavailable) }
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return .success(()) }
    do {
      let data = try Data(contentsOf: fileURL)
      var payload = try JSONDecoder().decode(HomeSnapshotsPayload.self, from: data)
      guard payload.version == HomeSnapshot.currentVersion else { return .failure(.corrupt) }
      payload.entries.removeAll { $0.serverID == serverID }
      if payload.entries.isEmpty {
        try FileManager.default.removeItem(at: fileURL)
      } else {
        try JSONEncoder().encode(payload).write(to: fileURL, options: .atomic)
      }
      return .success(())
    } catch {
      return .failure(.other)
    }
  }
}

private actor InMemoryHomeSnapshots {
  private var entries: [String: HomeSnapshot] = [:]

  func read(_ serverID: String) -> Result<HomeSnapshot?, HomeSnapshotFailure> {
    .success(entries[serverID])
  }

  func write(_ snapshot: HomeSnapshot) -> Result<Bool, HomeSnapshotFailure> {
    guard snapshot.isCurrent else { return .failure(.encoding) }
    entries[snapshot.serverID] = snapshot
    if entries.count > HomeSnapshot.maximumServers {
      let keep = entries.values.sorted { $0.capturedAt > $1.capturedAt }
        .prefix(HomeSnapshot.maximumServers)
        .map(\.serverID)
      entries = entries.filter { keep.contains($0.key) }
    }
    return .success(true)
  }

  func remove(_ serverID: String) -> Result<Void, HomeSnapshotFailure> {
    entries[serverID] = nil
    return .success(())
  }
}

// MARK: - Local records

/// Phone-local session records. Their keys are server-scoped (`serverID|sessionID`) so switching
/// servers cannot read another server's pins, read dates or unread marks.
public enum HomeSharedKeys {
  public static let pinnedSessions = SharedKey<[String]>(
    name: "followed-sessions",
    defaultValue: [],
    storage: .userDefaults
  )

  public static let sessionReadDates = SharedKey<[String: Date]>(
    name: "session-read-dates",
    defaultValue: [:],
    storage: .userDefaults
  )

  public static let manuallyUnreadSessions = SharedKey<Set<String>>(
    name: "manually-unread-sessions",
    defaultValue: [],
    storage: .userDefaults
  )

  public static let mutedSessions = SharedKey<Set<String>>(
    name: "muted-sessions",
    defaultValue: [],
    storage: .userDefaults
  )

  public static let hiddenSessions = SharedKey<Set<String>>(
    name: "hidden-sessions",
    defaultValue: [],
    storage: .userDefaults
  )

  public static let lastViewedSessions = SharedKey<[String: String]>(
    name: "last-viewed-sessions",
    defaultValue: [:],
    storage: .userDefaults
  )

  public static let whatsNewSeen = SharedKey<Set<String>>(
    name: "whats-new-seen",
    defaultValue: [],
    storage: .userDefaults
  )

  public static let names: [String] = [
    pinnedSessions.name,
    sessionReadDates.name,
    manuallyUnreadSessions.name,
    mutedSessions.name,
    hiddenSessions.name,
    lastViewedSessions.name,
    whatsNewSeen.name,
  ]
}

// MARK: - What's New

/// Where a What's New entry's action goes. A destination that this build does not implement is
/// explicitly unavailable rather than a dead control.
public enum WhatsNewDestination: Equatable, Sendable {
  case newSession
  case prompt(String)
  case appearance
  case sessions
  case servers
  case modelPicker
  case experiment(String)
  case unavailable(String)
}

/// One shipped What's New entry, including its audited day, copy and Try It destination.
public struct WhatsNewEntry: Equatable, Sendable, Identifiable {
  public enum Kind: String, Equatable, Sendable {
    case feature
    case smaller
  }

  public var id: String
  public var day: String
  public var kind: Kind
  public var title: String
  public var symbol: String
  public var tint: String
  public var summary: String
  public var details: [String]
  public var example: String?
  public var destination: WhatsNewDestination?

  public init(
    id: String,
    day: String,
    kind: Kind = .feature,
    title: String,
    symbol: String = "sparkles",
    tint: String = "blue",
    summary: String,
    details: [String] = [],
    example: String? = nil,
    destination: WhatsNewDestination? = nil
  ) {
    self.id = id
    self.day = day
    self.kind = kind
    self.title = title
    self.symbol = symbol
    self.tint = tint
    self.summary = summary
    self.details = details
    self.example = example
    self.destination = destination
  }
}

/// The entries this build ships. See `WhatsNewCatalogue` for the reconstructed catalogue.
public struct WhatsNewCatalog: Sendable, Equatable {
  public var entries: [WhatsNewEntry]

  public init(entries: [WhatsNewEntry]) {
    self.entries = entries.sorted { lhs, rhs in
      if lhs.day != rhs.day { return lhs.day > rhs.day }
      return lhs.id < rhs.id
    }
  }

  public func unseen(seen: Set<String>) -> [WhatsNewEntry] {
    entries.filter { !seen.contains($0.id) }
  }

  public var ids: Set<String> { Set(entries.map(\.id)) }

  public static let migration = WhatsNewCatalog(entries: WhatsNewCatalogue.entries)
}

extension WhatsNewCatalog: DependencyKey {
  public static let liveValue = WhatsNewCatalog.migration
  public static let testValue = WhatsNewCatalog.migration
}

extension DependencyValues {
  public var whatsNewCatalog: WhatsNewCatalog {
    get { self[WhatsNewCatalog.self] }
    set { self[WhatsNewCatalog.self] = newValue }
  }
}

public struct WhatsNewState: Equatable, Sendable {
  public var isPresented: Bool
  public var seenIDs: Set<String>

  public init(isPresented: Bool = false, seenIDs: Set<String> = []) {
    self.isPresented = isPresented
    self.seenIDs = seenIDs
  }
}

// MARK: - Catch Up

public enum CatchUpDisposition: Equatable, Sendable {
  case markRead
  case keepUnread
}

public struct CatchUpState: Equatable, Sendable {
  public struct Handled: Equatable, Sendable {
    public var sessionID: String
    public var disposition: CatchUpDisposition
    public var idleMilliseconds: Int64?
    public var updatedAt: Date
    public var neededAttention: Bool

    public init(
      sessionID: String,
      disposition: CatchUpDisposition,
      idleMilliseconds: Int64?,
      updatedAt: Date,
      neededAttention: Bool
    ) {
      self.sessionID = sessionID
      self.disposition = disposition
      self.idleMilliseconds = idleMilliseconds
      self.updatedAt = updatedAt
      self.neededAttention = neededAttention
    }

    /// New activity after the card was handled brings it back this pass.
    public func isSuperseded(by session: OpenCodeSession, needsAttention: Bool) -> Bool {
      if needsAttention && !neededAttention { return true }
      if let idle = session.idleMilliseconds, let handled = idleMilliseconds {
        return idle > handled
      }
      return session.updatedAt > updatedAt
    }
  }

  /// What a Mark Read changed, so Undo can put the card back exactly as it was.
  public struct ReadBackup: Equatable, Sendable {
    public var idleMilliseconds: Int64?
    public var viewedMilliseconds: Int64?
    public var readDate: Date?
    public var wasManuallyUnread: Bool
    /// A view event at or below this watermark must not clear a deliberate unread mark.
    public var unreadFloorMilliseconds: Int64?

    public init(
      idleMilliseconds: Int64?,
      viewedMilliseconds: Int64?,
      readDate: Date?,
      wasManuallyUnread: Bool,
      unreadFloorMilliseconds: Int64? = nil
    ) {
      self.idleMilliseconds = idleMilliseconds
      self.viewedMilliseconds = viewedMilliseconds
      self.readDate = readDate
      self.wasManuallyUnread = wasManuallyUnread
      self.unreadFloorMilliseconds = unreadFloorMilliseconds
    }
  }

  public struct Undo: Equatable, Sendable {
    public var sessionID: String
    public var disposition: CatchUpDisposition
    public var backup: ReadBackup?

    public init(sessionID: String, disposition: CatchUpDisposition, backup: ReadBackup?) {
      self.sessionID = sessionID
      self.disposition = disposition
      self.backup = backup
    }
  }

  public var queue: [String]
  public var handled: [Handled]
  public var returnSessionID: String?
  public var lastUndo: Undo?
  public var problem: String?

  public init(
    queue: [String] = [],
    handled: [Handled] = [],
    returnSessionID: String? = nil,
    lastUndo: Undo? = nil,
    problem: String? = nil
  ) {
    self.queue = queue
    self.handled = handled
    self.returnSessionID = returnSessionID
    self.lastUndo = lastUndo
    self.problem = problem
  }

  public var openCardID: String? { queue.first }
  public var isFinished: Bool { queue.isEmpty }
}
