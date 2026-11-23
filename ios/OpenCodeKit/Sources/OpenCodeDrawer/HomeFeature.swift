import ComposableArchitecture
import Foundation
import OpenCodeCore
import OpenCodeServer

/// The connected home: the drawer's session lists, pins, read state, search, paging, Catch Up and
/// What's New. `AppFeature` owns the connection and the event stream; this reducer is the one
/// consumer of their results and re-reads REST after every reconnect or overflow.
@Reducer
public struct HomeFeature {
  @ObservableState
  public struct State: Equatable, Sendable {
    public struct PageState: Equatable, Sendable {
      public var next: String?
      public var isLoading: Bool
      public var failed: Bool
      public var pagesLoaded: Int

      public init(next: String? = nil, isLoading: Bool = false, failed: Bool = false, pagesLoaded: Int = 0) {
        self.next = next
        self.isLoading = isLoading
        self.failed = failed
        self.pagesLoaded = pagesLoaded
      }

      public var canLoad: Bool { next != nil && !isLoading && !failed }
    }

    public struct SearchState: Equatable, Sendable {
      public var query: String
      public var results: [OpenCodeSession]
      public var next: String?
      public var isLoading: Bool
      public var failed: Bool

      public init(
        query: String,
        results: [OpenCodeSession] = [],
        next: String? = nil,
        isLoading: Bool = false,
        failed: Bool = false
      ) {
        self.query = query
        self.results = results
        self.next = next
        self.isLoading = isLoading
        self.failed = failed
      }

      public var canLoad: Bool { next != nil && !isLoading && !failed }
    }

    public struct DeletionBackup: Equatable, Sendable {
      public var session: OpenCodeSession
      public var index: Int
      public var wasActive: Bool
      public var neededAttention: Bool
      /// False for a search-only match that the loaded list did not hold.
      public var wasListed: Bool

      public init(
        session: OpenCodeSession,
        index: Int,
        wasActive: Bool,
        neededAttention: Bool,
        wasListed: Bool = true
      ) {
        self.session = session
        self.index = index
        self.wasActive = wasActive
        self.neededAttention = neededAttention
        self.wasListed = wasListed
      }
    }

    public var server: OpenCodeServer
    public var projects: [ServerProject]
    public var sessions: [OpenCodeSession]
    public var activeSessionIDs: Set<String>
    public var attentionSessionIDs: Set<String>

    public var pinnedKeys: [String]
    public var readDates: [String: Date]
    public var manuallyUnreadKeys: Set<String>
    public var mutedKeys: Set<String>
    public var hiddenKeys: Set<String>
    public var lastViewed: [String: String]

    public var searchText: String
    public var search: SearchState?
    public var page: PageState
    public var isLive: Bool
    public var hasLoaded: Bool
    public var loadedFromCache: Bool
    public var notice: HomeNotice?
    public var isDrawerOpen: Bool
    public var showsServerSwitcher: Bool

    public var pendingDeletion: SessionDeletion?
    public var recentDeletedIDs: Set<String>

    public var catchUp: CatchUpState?
    public var whatsNew: WhatsNewState
    public var whatsNewEntries: [WhatsNewEntry]
    public var catchUpFinished: Bool
    public var isPinned: Bool

    public var generation: Int
    public var refreshRequest: Int
    public var searchToken: Int
    var isRefreshing: Bool
    var refreshQueued: Bool
    var readReceipts: [String: ReadReceipt]
    /// Mark All's receipts, so a failed view watermark can restore that session's read state.
    public var markAllReceipts: [String: CatchUpState.ReadBackup]
    /// Session ID -> idle watermark at or below which a delayed view event is stale for a
    /// deliberate unread mark or an undone read.
    var unreadFloors: [String: Int64]
    /// Deletes whose server outcome is not settled. They survive disconnect and are verified by a
    /// targeted session read after reconnect; absence from the first page proves nothing.
    var pendingDeletions: [String: PendingDeletion]
    /// Session ID -> the refresh counter at which the server confirmed deletion. Tombstones are
    /// kept for the Home lifetime so an older refresh cannot resurrect a deleted row.
    var deletionTombstones: [String: Int]
    /// Directories a cold attention event taught us about; a later full attention read includes
    /// them without scanning every project.
    var attentionHints: [String]

    public struct SessionDeletion: Equatable, Sendable {
      public var session: OpenCodeSession

      public init(session: OpenCodeSession) {
        self.session = session
      }
    }

    struct PendingDeletion: Equatable, Sendable {
      var backup: DeletionBackup
      var operationID: UUID
      /// The DELETE request has not produced an operation result yet.
      var isRunning: Bool
      /// A targeted read must establish the outcome before local records are touched.
      var needsVerification: Bool
    }

    struct ReadReceipt: Equatable, Sendable {
      var id: UUID
      var idle: Int64
      var backup: CatchUpState.ReadBackup
    }

    public init(
      server: OpenCodeServer,
      projects: [ServerProject] = [],
      sessions: [OpenCodeSession] = [],
      activeSessionIDs: Set<String> = [],
      attentionSessionIDs: Set<String> = [],
      pinnedKeys: [String] = [],
      readDates: [String: Date] = [:],
      manuallyUnreadKeys: Set<String> = [],
      mutedKeys: Set<String> = [],
      hiddenKeys: Set<String> = [],
      lastViewed: [String: String] = [:],
      searchText: String = "",
      isLive: Bool = true,
      hasLoaded: Bool = false,
      loadedFromCache: Bool = false,
      isDrawerOpen: Bool = false,
      showsServerSwitcher: Bool = false,
      whatsNew: WhatsNewState = WhatsNewState(),
      whatsNewEntries: [WhatsNewEntry] = WhatsNewCatalog.migration.entries,
      catchUpFinished: Bool = false,
      isPinned: Bool = false
    ) {
      self.server = server
      self.projects = projects
      self.sessions = sessions
      self.activeSessionIDs = activeSessionIDs
      self.attentionSessionIDs = attentionSessionIDs
      self.pinnedKeys = pinnedKeys
      self.readDates = readDates
      self.manuallyUnreadKeys = manuallyUnreadKeys
      self.mutedKeys = mutedKeys
      self.hiddenKeys = hiddenKeys
      self.lastViewed = lastViewed
      self.searchText = searchText
      self.search = nil
      self.page = PageState()
      self.isLive = isLive
      self.hasLoaded = hasLoaded
      self.loadedFromCache = loadedFromCache
      self.notice = nil
      self.isDrawerOpen = isDrawerOpen
      self.showsServerSwitcher = showsServerSwitcher
      self.pendingDeletion = nil
      self.recentDeletedIDs = []
      self.catchUp = nil
      self.whatsNew = whatsNew
      self.whatsNewEntries = whatsNewEntries
      self.catchUpFinished = catchUpFinished
      self.isPinned = isPinned
      self.generation = 1
      self.refreshRequest = 0
      self.searchToken = 0
      self.isRefreshing = false
      self.refreshQueued = false
      self.readReceipts = [:]
      self.markAllReceipts = [:]
      self.unreadFloors = [:]
      self.pendingDeletions = [:]
      self.deletionTombstones = [:]
      self.attentionHints = []
    }

    /// Effect bookkeeping stays out of equality; tokens only guard late callbacks.
    public static func == (lhs: State, rhs: State) -> Bool {
      lhs.server == rhs.server
        && lhs.projects == rhs.projects
        && lhs.sessions == rhs.sessions
        && lhs.activeSessionIDs == rhs.activeSessionIDs
        && lhs.attentionSessionIDs == rhs.attentionSessionIDs
        && lhs.pinnedKeys == rhs.pinnedKeys
        && lhs.readDates == rhs.readDates
        && lhs.manuallyUnreadKeys == rhs.manuallyUnreadKeys
        && lhs.mutedKeys == rhs.mutedKeys
        && lhs.hiddenKeys == rhs.hiddenKeys
        && lhs.lastViewed == rhs.lastViewed
        && lhs.searchText == rhs.searchText
        && lhs.search == rhs.search
        && lhs.page == rhs.page
        && lhs.isLive == rhs.isLive
        && lhs.hasLoaded == rhs.hasLoaded
        && lhs.loadedFromCache == rhs.loadedFromCache
        && lhs.notice == rhs.notice
        && lhs.isDrawerOpen == rhs.isDrawerOpen
        && lhs.showsServerSwitcher == rhs.showsServerSwitcher
        && lhs.pendingDeletion == rhs.pendingDeletion
        && lhs.recentDeletedIDs == rhs.recentDeletedIDs
        && lhs.catchUp == rhs.catchUp
        && lhs.whatsNew == rhs.whatsNew
        && lhs.whatsNewEntries == rhs.whatsNewEntries
        && lhs.catchUpFinished == rhs.catchUpFinished
        && lhs.isPinned == rhs.isPinned
    }

    // MARK: Derived

    public var serverID: String { server.persistenceID }

    public func key(_ sessionID: String) -> String { "\(server.persistenceID)|\(sessionID)" }

    public func isPinned(_ sessionID: String) -> Bool { pinnedKeys.contains(key(sessionID)) }

    public func isHidden(_ sessionID: String) -> Bool { hiddenKeys.contains(key(sessionID)) }

    public func isMuted(_ sessionID: String) -> Bool { mutedKeys.contains(key(sessionID)) }

    public func isUnread(_ session: OpenCodeSession) -> Bool {
      let key = key(session.id)
      if manuallyUnreadKeys.contains(key) { return true }
      if let idle = session.idleMilliseconds {
        return idle > (session.viewedMilliseconds ?? -1)
      }
      if let read = readDates[key] { return read < session.updatedAt }
      return true
    }

    public func indicator(_ session: OpenCodeSession) -> DrawerIndicator {
      guard isLive else { return .none }
      if attentionSessionIDs.contains(session.id) { return .attention }
      if activeSessionIDs.contains(session.id) { return .running }
      if isUnread(session), !isMuted(session.id) { return .unread }
      return .none
    }

    /// Root sessions only; pinned and recent ordering is computed once per change.
    public var visibleSessions: [OpenCodeSession] {
      let roots = sessions.filter { $0.parentID == nil && !$0.isArchived }
      guard !searchText.isEmpty else {
        return roots.filter { !isHidden($0.id) && !recentDeletedIDs.contains($0.id) }
      }
      let local = roots.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
      guard let search else { return local }
      var known = Set(roots.map(\.id))
      var extra: [OpenCodeSession] = []
      for result in search.results {
        guard !known.contains(result.id), result.parentID == nil, !result.isArchived else { continue }
        guard !recentDeletedIDs.contains(result.id) else { continue }
        guard search.query == searchText.trimmingCharacters(in: .whitespacesAndNewlines)
          || result.title.localizedCaseInsensitiveContains(searchText)
        else { continue }
        known.insert(result.id)
        extra.append(result)
      }
      return local + extra
    }

    public struct DrawerSessions: Equatable, Sendable {
      public var pinned: [OpenCodeSession]
      public var recents: [OpenCodeSession]

      public init(pinned: [OpenCodeSession] = [], recents: [OpenCodeSession] = []) {
        self.pinned = pinned
        self.recents = recents
      }
    }

    public var drawerSessions: DrawerSessions {
      let visible = visibleSessions
      let prefix = server.persistenceID + "|"
      let pinnedIDs = pinnedKeys.compactMap { key -> String? in
        guard key.hasPrefix(prefix) else { return nil }
        return String(key.dropFirst(prefix.count))
      }
      guard !pinnedIDs.isEmpty else {
        return DrawerSessions(recents: visible.sorted { $0.updatedAt > $1.updatedAt })
      }
      let pinnedSet = Set(pinnedIDs)
      let byID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      let pinned = pinnedIDs.compactMap { byID[$0] }
      let recents = visible.filter { !pinnedSet.contains($0.id) }.sorted { $0.updatedAt > $1.updatedAt }
      return DrawerSessions(pinned: pinned, recents: recents)
    }

    public func needsCatchUp(_ session: OpenCodeSession) -> Bool {
      guard session.parentID == nil, !session.isArchived, !isMuted(session.id) else { return false }
      switch indicator(session) {
      case .attention, .unread: return true
      case .running, .none: return false
      }
    }

    /// Waiting first, then newest.
    public var catchUpSessions: [OpenCodeSession] {
      sessions
        .filter { needsCatchUp($0) && !recentDeletedIDs.contains($0.id) }
        .sorted { a, b in
          let aWaiting = attentionSessionIDs.contains(a.id)
          let bWaiting = attentionSessionIDs.contains(b.id)
          if aWaiting != bWaiting { return aWaiting }
          return a.updatedAt > b.updatedAt
        }
    }

    public func session(_ id: String) -> OpenCodeSession? {
      sessions.first { $0.id == id } ?? search?.results.first { $0.id == id }
    }

    public var unseenWhatsNew: [WhatsNewEntry] {
      whatsNewEntries.filter { !whatsNew.seenIDs.contains($0.id) }
    }

    public var showsWhatsNewRow: Bool { !unseenWhatsNew.isEmpty }

    public var catchUpCard: OpenCodeSession? {
      guard let catchUp, let id = catchUp.queue.first else { return nil }
      return session(id)
    }

    public func receiptID(for sessionID: String) -> UUID? {
      readReceipts[sessionID]?.id
    }

    public func isDeletionInFlight(_ sessionID: String) -> Bool {
      pendingDeletions[sessionID] != nil
    }

    public func isDeletionConfirmed(_ sessionID: String) -> Bool {
      deletionTombstones[sessionID] != nil
    }

    public func deletionOperationID(_ sessionID: String) -> UUID? {
      pendingDeletions[sessionID]?.operationID
    }

    /// Whether Mark All has an unread row to acknowledge. Waiting and running rows keep their state.
    public var canMarkAllRead: Bool {
      sessions.contains { indicator($0) == .unread }
    }

    public var drawerBadge: DrawerIndicator? {
      guard isLive else { return nil }
      for session in sessions where !session.isArchived && !isMuted(session.id) {
        if attentionSessionIDs.contains(session.id) { return .attention }
      }
      for session in sessions where !session.isArchived && !isMuted(session.id) {
        if isUnread(session), indicator(session) == .unread { return .unread }
      }
      return nil
    }
  }

  public enum Action: Equatable, Sendable {
    case task
    case localStateLoaded
    case cacheLoaded(generation: Int, result: Result<HomeSnapshot?, HomeSnapshotFailure>)
    case refreshed(
      generation: Int,
      request: Int,
      result: Result<HomeRefresh, OpenCodeClientError>
    )
    case snapshotWritten(generation: Int, result: Result<Bool, HomeSnapshotFailure>)
    case retryRefreshTapped
    case connectionChanged(isConnected: Bool)
    case connectionResynchronized
    case projectsChanged([ServerProject])
    case serverEvent(ServerEvent)

    case attentionRefreshed(generation: Int, result: Result<Set<String>, OpenCodeClientError>)
    case attentionEventResolved(
      generation: Int,
      askedID: String,
      rootID: String,
      directory: String,
      result: Result<Set<String>, OpenCodeClientError>
    )

    case loadMoreTapped
    case olderLoaded(generation: Int, cursor: String, result: Result<SessionPage, OpenCodeClientError>)
    case searchChanged(String)
    case searchLoaded(
      generation: Int,
      query: String,
      token: Int,
      appending: Bool,
      result: Result<SessionPage, OpenCodeClientError>
    )

    case pinToggled(String)
    case markReadTapped(String)
    case markUnreadTapped(String)
    case markAllReadTapped
    case markAllReceiptFinished(
      generation: Int,
      sessionID: String,
      idle: Int64,
      succeeded: Bool
    )
    case readReceiptFinished(
      generation: Int,
      sessionID: String,
      receiptID: UUID,
      result: Result<Bool, OpenCodeClientError>
    )

    case drawerToggled
    case drawerDismissed
    case newSessionTapped(directory: String?)
    case sessionTapped(String)
    case serverSwitcherTapped
    case serverSwitcherDismissed
    case savedServerSelected(OpenCodeServer)

    case deleteTapped(String)
    case deleteCancelled
    case deleteConfirmed
    case deletionFinished(
      serverID: String,
      sessionID: String,
      operationID: UUID,
      result: Result<Bool, OpenCodeClientError>
    )
    case deletionVerified(
      generation: Int,
      serverID: String,
      sessionID: String,
      operationID: UUID,
      outcome: DeletionVerification
    )
    case noticeExpired

    case catchUpTapped
    case catchUpCardDismissed(sessionID: String, disposition: CatchUpDisposition)
    case catchUpUndoTapped
    case catchUpExitTapped
    case catchUpOpenTapped
    case catchUpProblemDismissed

    case whatsNewTapped
    case whatsNewViewed
    case whatsNewDismissed

    case delegate(Delegate)
  }

  public enum Delegate: Equatable, Sendable {
    case openSession(SessionSelection)
    case newSession(directory: String)
    case switchServer(OpenCodeServer)
    case disconnect
  }

  enum CancelID: Hashable {
    case cache
    case refresh
    case attention
    case olderPage
    case search
    case searchPage
    case snapshotWrite
    case notice
    case readReceipt(String)
    case markAllReceipts
    case deletion(String)
    case deletionVerification(String)
  }

  @Dependency(\.openCodeClient) private var client
  @Dependency(\.clock) private var clock
  @Dependency(\.sharedStore) private var store
  @Dependency(\.homeSnapshotStore) private var snapshots
  @Dependency(\.whatsNewCatalog) private var whatsNewCatalog
  @Dependency(\.dateClient) private var date
  @Dependency(\.uuidClient) private var uuid
  @Dependency(\.haptics) private var haptics

  public init() {}

  public var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        state.whatsNewEntries = whatsNewCatalog.entries
        loadLocalState(&state)
        guard !state.isPinned else {
          state.hasLoaded = true
          return .none
        }
        let generation = state.generation
        let refresh: Effect<Action> =
          state.isRefreshing ? .none : startRefresh(&state, delay: .zero)
        return .merge(
          cacheEffect(serverID: state.serverID, generation: generation),
          refresh
        )

      case .localStateLoaded:
        loadLocalState(&state)
        return .none

      case .cacheLoaded(let generation, let result):
        guard generation == state.generation, !state.isPinned else { return .none }
        guard !state.hasLoaded || state.loadedFromCache else { return .none }
        switch result {
        case .success(let snapshot):
          guard let snapshot, snapshot.serverID == state.serverID else { return .none }
          state.loadedFromCache = true
          state.hasLoaded = true
          if state.projects.isEmpty { state.projects = snapshot.projects }
          state.sessions = mergeSessions(snapshot.sessions, into: state)
          state.activeSessionIDs = Set(snapshot.activeSessionIDs)
          state.page.next = snapshot.nextCursor
        case .failure(let failure):
          state.notice = .couldNotReadSnapshot(failure)
        }
        return .none

      case .refreshed(let generation, let request, let result):
        guard generation == state.generation, !state.isPinned else { return .none }
        guard request == state.refreshRequest else { return .none }
        state.isRefreshing = false
        switch result {
        case .success(let refresh):
          state.hasLoaded = true
          state.loadedFromCache = false
          state.sessions = mergeSessions(refresh.sessions, into: state)
          state.activeSessionIDs = refresh.activeSessionIDs
          state.page.next = refresh.next
          state.page.failed = false
          state.notice = nil
          reconcileCatchUp(&state)
          AppLog(category: .app).event(
            .connectionReady,
            [LogField("sessions", .count(state.sessions.count))]
          )
          let snapshot = makeSnapshot(state)
          let attention = attentionEffect(&state)
          let write = snapshotWriteEffect(snapshot: snapshot, generation: generation)
          if state.refreshQueued {
            state.refreshQueued = false
            return .merge(write, attention, startRefresh(&state, delay: .milliseconds(250)))
          }
          return .merge(write, attention)
        case .failure(let error):
          state.notice = .couldNotRefresh(.from(error, isOffline: !state.isLive))
          if state.refreshQueued {
            state.refreshQueued = false
            return startRefresh(&state, delay: .milliseconds(250))
          }
          return .none
        }

      case .snapshotWritten(let generation, let result):
        guard generation == state.generation else { return .none }
        if case .failure(let failure) = result {
          state.notice = .couldNotSaveSnapshot(failure)
        } else {
          removeLegacyProjectSummary(serverID: state.serverID)
        }
        return .none

      case .retryRefreshTapped:
        return startRefresh(&state, delay: .zero)

      case .connectionChanged(let isConnected):
        if isConnected {
          guard !state.isLive else { return .none }
          state.isLive = true
          return .merge(
            startRefresh(&state, delay: .zero),
            verifyPendingDeletions(&state)
          )
        }
        state.isLive = false
        state.isRefreshing = false
        state.refreshQueued = false
        state.page.isLoading = false
        state.search?.isLoading = false
        state.readReceipts = [:]
        state.generation += 1
        return cancelServerWork()

      case .connectionResynchronized:
        state.isLive = true
        guard !state.isPinned else { return .none }
        // A fresh Home's first read started in .task already covers the handshake. Once data is
        // shown, a reconnect replaces any read that started before it with one authoritative read.
        if state.isRefreshing && !state.hasLoaded { return .none }
        return startRefresh(&state, delay: .zero, replacingInFlight: true)

      case .projectsChanged(let projects):
        state.projects = projects
        return .none

      case .serverEvent(let event):
        return reduce(event: event, state: &state)

      case .attentionRefreshed(let generation, let result):
        guard generation == state.generation, !state.isPinned else { return .none }
        if case .success(let ids) = result {
          state.attentionSessionIDs = ids
          reconcileCatchUp(&state)
        }
        return .none

      case .attentionEventResolved(let generation, _, let rootID, let directory, let result):
        guard generation == state.generation, !state.isPinned else { return .none }
        addAttentionHint(directory, state: &state)
        switch result {
        case .success(let ids):
          state.attentionSessionIDs.formUnion(ids)
          // A cold session's own directory may report it before the Home page lists it.
          if ids.isEmpty { state.attentionSessionIDs.insert(rootID) }
        case .failure:
          // Keep the event's own answer rather than dropping the indicator on a read failure.
          state.attentionSessionIDs.insert(rootID)
        }
        let needsRow = !state.sessions.contains { $0.id == rootID }
        reconcileCatchUp(&state)
        return needsRow ? startRefresh(&state, delay: .milliseconds(250)) : .none

      case .loadMoreTapped:
        return loadMore(&state)

      case .olderLoaded(let generation, let cursor, let result):
        guard generation == state.generation, state.page.next == cursor else { return .none }
        state.page.isLoading = false
        switch result {
        case .success(let page):
          let known = Set(state.sessions.map(\.id))
          let added = page.sessions.filter {
            !known.contains($0.id) && !$0.isArchived && $0.parentID == nil
              && !state.recentDeletedIDs.contains($0.id)
          }
          state.sessions += added
          state.page.next = page.next
          state.page.pagesLoaded += 1
          state.page.failed = false
          seedReadDates(&state, sessions: added)
        case .failure:
          state.page.failed = true
          state.notice = .couldNotLoadOlder
        }
        return .none

      case .searchChanged(let text):
        return reduceSearchChanged(text, state: &state)

      case .searchLoaded(let generation, let query, let token, let appending, let result):
        guard generation == state.generation, token == state.searchToken else { return .none }
        guard var search = state.search, search.query == query, state.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
          return .none
        }
        search.isLoading = false
        switch result {
        case .success(let page):
          let accepted = page.sessions.filter {
            $0.parentID == nil && !$0.isArchived && !state.recentDeletedIDs.contains($0.id)
          }
          seedReadDates(&state, sessions: accepted)
          if appending {
            let known = Set(search.results.map(\.id))
            search.results += accepted.filter { !known.contains($0.id) }
          } else {
            search.results = accepted
          }
          search.next = page.next
          search.failed = false
        case .failure:
          search.failed = true
        }
        state.search = search
        return .none

      case .pinToggled(let sessionID):
        let key = state.key(sessionID)
        if let index = state.pinnedKeys.firstIndex(of: key) {
          state.pinnedKeys.remove(at: index)
        } else {
          state.pinnedKeys.append(key)
        }
        _ = store.write(state.pinnedKeys, for: HomeSharedKeys.pinnedSessions)
        return .none

      case .markReadTapped(let sessionID):
        guard let session = state.session(sessionID) else { return .none }
        let result = markRead(session, state: &state)
        return result.effect

      case .markAllReadTapped:
        return markAllRead(&state)

      case .markAllReceiptFinished(let generation, let sessionID, let idle, let succeeded):
        guard generation == state.generation,
          let backup = state.markAllReceipts[sessionID],
          backup.idleMilliseconds == idle
        else { return .none }
        state.markAllReceipts[sessionID] = nil
        if succeeded {
          acknowledgeView(sessionID: sessionID, idle: idle, state: &state)
        } else {
          restoreRead(backup, sessionID: sessionID, state: &state)
          if let session = state.session(sessionID) {
            state.notice = .couldNotMarkRead(title: session.title)
          }
        }
        return .none

      case .markUnreadTapped(let sessionID):
        guard let session = state.session(sessionID) else { return .none }
        markUnread(session, state: &state)
        return .cancel(id: CancelID.readReceipt(session.id))

      case .readReceiptFinished(let generation, let sessionID, let receiptID, let result):
        guard generation == state.generation else { return .none }
        guard let receipt = state.readReceipts[sessionID], receipt.id == receiptID else { return .none }
        state.readReceipts[sessionID] = nil
        switch result {
        case .success:
          // Acknowledge only the watermark this receipt carried. Newer activity that arrived
          // while it was in flight must stay unread.
          acknowledgeView(sessionID: sessionID, idle: receipt.idle, state: &state)
        case .failure(let error):
          restoreRead(receipt.backup, sessionID: sessionID, state: &state)
          let title = state.session(sessionID)?.title ?? ""
          if state.catchUp != nil {
            state.catchUp?.problem = title
          } else {
            state.notice = .couldNotMarkRead(title: title)
          }
          _ = error
        }
        return .none

      case .drawerToggled:
        state.isDrawerOpen.toggle()
        return .none

      case .drawerDismissed:
        state.isDrawerOpen = false
        return .none

      case .newSessionTapped(let directory):
        state.isDrawerOpen = false
        guard let directory = directory ?? state.projects.first?.directory else { return .none }
        return .send(.delegate(.newSession(directory: directory)))

      case .sessionTapped(let sessionID):
        guard let session = state.session(sessionID) else { return .none }
        state.isDrawerOpen = false
        state.lastViewed[state.serverID] = sessionID
        _ = store.write(state.lastViewed, for: HomeSharedKeys.lastViewedSessions)
        let read = markRead(session, state: &state)
        return .merge(
          read.effect,
          .send(.delegate(.openSession(SessionSelection(serverID: state.serverID, sessionID: sessionID, intent: .browse))))
        )

      case .serverSwitcherTapped:
        state.showsServerSwitcher = true
        return .none

      case .serverSwitcherDismissed:
        state.showsServerSwitcher = false
        return .none

      case .savedServerSelected(let server):
        state.showsServerSwitcher = false
        return .send(.delegate(.switchServer(server)))

      case .deleteTapped(let sessionID):
        guard let session = state.session(sessionID) else { return .none }
        state.pendingDeletion = State.SessionDeletion(session: session)
        return .none

      case .deleteCancelled:
        state.pendingDeletion = nil
        return .none

      case .deleteConfirmed:
        return confirmDeletion(&state)

      case .deletionFinished(let serverID, let sessionID, let operationID, let result):
        guard serverID == state.serverID else { return .none }
        guard var pending = state.pendingDeletions[sessionID],
          pending.operationID == operationID
        else { return .none }
        switch result {
        case .success:
          state.pendingDeletions[sessionID] = nil
          confirmDeleted(pending.backup, state: &state)
          return .none
        case .failure(let error):
          switch deletionFailureKind(error) {
          case .confirmed:
            state.pendingDeletions[sessionID] = nil
            confirmDeleted(pending.backup, state: &state)
            return .none
          case .failed:
            state.pendingDeletions[sessionID] = nil
            state.deletionTombstones[sessionID] = nil
            restoreDeletion(pending.backup, state: &state)
            state.notice = .couldNotDelete(title: pending.backup.session.title)
            return noticeExpiryEffect()
          case .uncertain:
            // The server may have acted. Keep the backup and the local records; a targeted read
            // decides the outcome. Never infer it from the first session page.
            pending.isRunning = false
            pending.needsVerification = true
            state.pendingDeletions[sessionID] = pending
            guard state.isLive else { return .none }
            return verifyDeletion(
              server: state.server,
              serverID: state.serverID,
              generation: state.generation,
              sessionID: sessionID,
              operationID: operationID
            )
          }
        }

      case .deletionVerified(let generation, let serverID, let sessionID, let operationID, let outcome):
        guard generation == state.generation, serverID == state.serverID else { return .none }
        guard var pending = state.pendingDeletions[sessionID],
          pending.operationID == operationID
        else { return .none }
        switch outcome {
        case .absent:
          state.pendingDeletions[sessionID] = nil
          confirmDeleted(pending.backup, state: &state)
          return .none
        case .present:
          if pending.isRunning {
            // The DELETE may still be in flight. Presence is an intermediate state, not a failure.
            pending.needsVerification = true
            state.pendingDeletions[sessionID] = pending
            return .none
          }
          state.pendingDeletions[sessionID] = nil
          state.deletionTombstones[sessionID] = nil
          restoreDeletion(pending.backup, state: &state)
          state.notice = .couldNotDelete(title: pending.backup.session.title)
          return noticeExpiryEffect()
        case .inconclusive:
          pending.needsVerification = true
          state.pendingDeletions[sessionID] = pending
          if !pending.isRunning {
            state.notice = .couldNotVerifyDeletion(title: pending.backup.session.title)
          }
          return .none
        }

      case .noticeExpired:
        state.notice = nil
        return .none

      case .catchUpTapped:
        state.catchUpFinished = false
        state.catchUp = CatchUpState(
          queue: state.catchUpSessions.map(\.id),
          handled: [],
          returnSessionID: state.lastViewed[state.serverID]
        )
        return .none

      case .catchUpCardDismissed(let sessionID, let disposition):
        return dismissCatchUpCard(sessionID: sessionID, disposition: disposition, state: &state)

      case .catchUpUndoTapped:
        return undoLastCatchUpCard(&state)

      case .catchUpExitTapped:
        state.catchUp = nil
        return .none

      case .catchUpOpenTapped:
        guard let catchUp = state.catchUp, let id = catchUp.queue.first else { return .none }
        return .send(
          .delegate(.openSession(SessionSelection(serverID: state.serverID, sessionID: id, intent: .catchUpCard)))
        )

      case .catchUpProblemDismissed:
        state.catchUp?.problem = nil
        return .none

      case .whatsNewTapped:
        state.whatsNew.isPresented = true
        return .none

      case .whatsNewViewed:
        markWhatsNewSeen(&state)
        return .none

      case .whatsNewDismissed:
        state.whatsNew.isPresented = false
        markWhatsNewSeen(&state)
        return .none

      case .delegate:
        return .none
      }
    }
  }

  // MARK: Local state

  private func loadLocalState(_ state: inout State) {
    if case .value(let value) = store.read(HomeSharedKeys.pinnedSessions) { state.pinnedKeys = value }
    if case .value(let value) = store.read(HomeSharedKeys.sessionReadDates) { state.readDates = value }
    if case .value(let value) = store.read(HomeSharedKeys.manuallyUnreadSessions) { state.manuallyUnreadKeys = value }
    if case .value(let value) = store.read(HomeSharedKeys.mutedSessions) { state.mutedKeys = value }
    if case .value(let value) = store.read(HomeSharedKeys.hiddenSessions) { state.hiddenKeys = value }
    if case .value(let value) = store.read(HomeSharedKeys.lastViewedSessions) { state.lastViewed = value }
    if case .value(let value) = store.read(HomeSharedKeys.whatsNewSeen) { state.whatsNew.seenIDs = value }
  }

  private func seedReadDates(_ state: inout State, sessions: [OpenCodeSession]) {
    var changed = false
    for session in sessions where session.idleMilliseconds == nil {
      let key = state.key(session.id)
      if state.readDates[key] == nil, session.viewedMilliseconds != nil {
        state.readDates[key] = session.updatedAt
        changed = true
      }
    }
    if changed { _ = store.write(state.readDates, for: HomeSharedKeys.sessionReadDates) }
  }

  // MARK: Refresh

  private func startRefresh(
    _ state: inout State,
    delay: Duration,
    replacingInFlight: Bool = false
  ) -> Effect<Action> {
    guard state.isLive, !state.isPinned else { return .none }
    if state.isRefreshing {
      if !replacingInFlight {
        state.refreshQueued = true
        return .none
      }
      state.refreshQueued = false
    }
    state.isRefreshing = true
    state.refreshRequest += 1
    let request = state.refreshRequest
    let generation = state.generation
    let server = state.server
    let client = client
    let clock = clock
    return .run { send in
      do {
        if delay > .zero { try await clock.sleep(delay) }
        async let page = client.sessionPage(server, .first, 50)
        async let active = client.activeSessionIDs(server)
        let (loaded, running) = try await (page, active)
        await send(
          .refreshed(
            generation: generation,
            request: request,
            result: .success(
              HomeRefresh(sessions: loaded.sessions, next: loaded.next, activeSessionIDs: running)
            )
          )
        )
      } catch is CancellationError {
        return
      } catch let error as OpenCodeClientError {
        await send(.refreshed(generation: generation, request: request, result: .failure(error)))
      } catch {
        await send(.refreshed(generation: generation, request: request, result: .failure(OpenCodeClientError(.unreachable))))
      }
    }
    .cancellable(id: CancelID.refresh, cancelInFlight: true)
  }

  private func cacheEffect(serverID: String, generation: Int) -> Effect<Action> {
    let snapshots = snapshots
    return .run { send in
      let result = await snapshots.read(serverID)
      await send(.cacheLoaded(generation: generation, result: result))
    }
    .cancellable(id: CancelID.cache, cancelInFlight: true)
  }

  private func snapshotWriteEffect(snapshot: HomeSnapshot, generation: Int) -> Effect<Action> {
    let snapshots = snapshots
    return .run { send in
      let result = await snapshots.write(snapshot)
      await send(
        .snapshotWritten(
          generation: generation,
          result: result.map { _ in true }
        )
      )
    }
    .cancellable(id: CancelID.snapshotWrite, cancelInFlight: true)
  }

  private func makeSnapshot(_ state: State) -> HomeSnapshot {
    HomeSnapshot(
      serverID: state.serverID,
      projects: state.projects,
      sessions: state.sessions.filter { $0.parentID == nil && !$0.isArchived }
        .sorted { $0.updatedAt > $1.updatedAt },
      activeSessionIDs: state.activeSessionIDs,
      nextCursor: state.page.next,
      capturedAt: date.now()
    )
  }

  /// REST already fetched the fresh page; older pages this phone loaded are kept so a refresh does
  /// not collapse the list under the reader.
  private func mergeSessions(_ fresh: [OpenCodeSession], into state: State) -> [OpenCodeSession] {
    let accepted = fresh.filter {
      $0.parentID == nil && !$0.isArchived && !state.recentDeletedIDs.contains($0.id)
    }
    guard state.page.pagesLoaded > 0 else { return accepted }
    let freshIDs = Set(accepted.map(\.id))
    let kept = state.sessions.filter {
      !freshIDs.contains($0.id) && !$0.isArchived && $0.parentID == nil
        && !state.recentDeletedIDs.contains($0.id)
    }
    return (accepted + kept).sorted { $0.updatedAt > $1.updatedAt }
  }

  private func removeLegacyProjectSummary(serverID: String) {
    guard case .value(var summaries) = store.read(ServerSharedKeys.cachedSummaries),
      summaries[serverID] != nil
    else { return }
    summaries[serverID] = nil
    _ = store.write(summaries, for: ServerSharedKeys.cachedSummaries)
  }

  // MARK: Attention

  private func attentionEffect(_ state: inout State) -> Effect<Action> {
    guard !state.isPinned else { return .none }
    let directories = attentionDirectories(state)
    guard !directories.isEmpty else {
      state.attentionSessionIDs = []
      return .none
    }
    let server = state.server
    let roots = state.sessions
    let generation = state.generation
    let client = client
    return .run { send in
      do {
        let ids = try await client.attentionSessionIDs(server, roots, directories)
        await send(.attentionRefreshed(generation: generation, result: .success(ids)))
      } catch is CancellationError {
        return
      } catch let error as OpenCodeClientError {
        await send(.attentionRefreshed(generation: generation, result: .failure(error)))
      } catch {
        await send(.attentionRefreshed(generation: generation, result: .failure(OpenCodeClientError(.unreachable))))
      }
    }
    .cancellable(id: CancelID.attention, cancelInFlight: true)
  }

  /// Only running, waiting and recently-read sessions can hold a request; a location read boots the
  /// server's full service graph for that directory, so the set stays small.
  private func attentionDirectories(_ state: State) -> [String] {
    let hot = state.sessions
      .filter {
        state.activeSessionIDs.contains($0.id)
          || state.attentionSessionIDs.contains($0.id)
          || state.lastViewed[state.serverID] == $0.id
      }
      .sorted { $0.updatedAt > $1.updatedAt }
    var seen = Set<String>()
    let ordered =
      hot.compactMap { session -> String? in
        let directory = session.directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return directory.isEmpty ? nil : directory
      }
      + state.attentionHints
    return ordered.compactMap { directory in
      guard seen.insert(directory).inserted else { return nil }
      return directory
    }
    .prefix(8)
    .map { $0 }
  }

  /// A pending request for a cold root or subagent names a directory no current row covers. One
  /// location read (and at most eight ancestry reads) resolves its root; no project scan happens.
  private func resolveAttentionEvent(_ askedID: String, state: inout State) -> Effect<Action> {
    let server = state.server
    let generation = state.generation
    let roots = state.sessions
    let client = client

    if let session = state.sessions.first(where: { $0.id == askedID }),
      let rootID = knownRootID(for: session, state: state)
    {
      optimisticAttention(rootID: rootID, directory: session.directory, state: &state)
      return directoryAttentionEffect(
        server: server,
        generation: generation,
        roots: roots,
        rootID: rootID,
        directory: session.directory
      )
    }

    return .run { send in
      do {
        var current = try await client.getSession(server, askedID)
        let directory = current.directory
        var rootID = current.id
        var hops = 0
        while let parent = current.parentID, hops < 8 {
          rootID = parent
          if roots.contains(where: { $0.id == parent }) { break }
          current = try await client.getSession(server, parent)
          hops += 1
        }
        let ids = try await client.attentionSessionIDs(server, roots, [directory])
        await send(
          .attentionEventResolved(
            generation: generation,
            askedID: askedID,
            rootID: rootID,
            directory: directory,
            result: .success(ids)
          )
        )
      } catch is CancellationError {
        return
      } catch let error as OpenCodeClientError {
        await send(
          .attentionEventResolved(
            generation: generation,
            askedID: askedID,
            rootID: askedID,
            directory: "",
            result: .failure(error)
          )
        )
      } catch {
        await send(
          .attentionEventResolved(
            generation: generation,
            askedID: askedID,
            rootID: askedID,
            directory: "",
            result: .failure(OpenCodeClientError(.unreachable))
          )
        )
      }
    }
    .cancellable(id: CancelID.attention, cancelInFlight: true)
  }

  private func directoryAttentionEffect(
    server: OpenCodeServer,
    generation: Int,
    roots: [OpenCodeSession],
    rootID: String,
    directory: String
  ) -> Effect<Action> {
    let client = client
    return .run { send in
      do {
        let ids = try await client.attentionSessionIDs(server, roots, [directory])
        await send(
          .attentionEventResolved(
            generation: generation,
            askedID: rootID,
            rootID: rootID,
            directory: directory,
            result: .success(ids)
          )
        )
      } catch is CancellationError {
        return
      } catch let error as OpenCodeClientError {
        await send(
          .attentionEventResolved(
            generation: generation,
            askedID: rootID,
            rootID: rootID,
            directory: directory,
            result: .failure(error)
          )
        )
      } catch {
        await send(
          .attentionEventResolved(
            generation: generation,
            askedID: rootID,
            rootID: rootID,
            directory: directory,
            result: .failure(OpenCodeClientError(.unreachable))
          )
        )
      }
    }
    .cancellable(id: CancelID.attention, cancelInFlight: true)
  }

  private func knownRootID(for session: OpenCodeSession, state: State) -> String? {
    var current = session
    var seen = Set<String>()
    while let parent = current.parentID {
      guard seen.insert(parent).inserted else { return nil }
      guard let parentSession = state.sessions.first(where: { $0.id == parent }) else { return nil }
      current = parentSession
    }
    return current.id
  }

  private func optimisticAttention(rootID: String, directory: String, state: inout State) {
    state.attentionSessionIDs.insert(rootID)
    addAttentionHint(directory, state: &state)
  }

  private func addAttentionHint(_ directory: String, state: inout State) {
    let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !state.attentionHints.contains(trimmed) else { return }
    state.attentionHints.append(trimmed)
    if state.attentionHints.count > 8 {
      state.attentionHints.removeFirst(state.attentionHints.count - 8)
    }
  }

  // MARK: Server events

  private func reduce(event: ServerEvent, state: inout State) -> Effect<Action> {
    switch event {
    case .connected:
      return .none
    case .sessionCreated, .sessionArchiveChanged(_, false):
      return startRefresh(&state, delay: .milliseconds(250))
    case .sessionRenamed(let id, let title):
      if let index = state.sessions.firstIndex(where: { $0.id == id }) {
        state.sessions[index].serverTitle = title
        return .none
      }
      return startRefresh(&state, delay: .milliseconds(250))
    case .sessionMoved(let id, let directory):
      if let index = state.sessions.firstIndex(where: { $0.id == id }) {
        state.sessions[index].directory = directory
        return .none
      }
      return .none
    case .sessionViewChanged(let id, let idle):
      let key = state.key(id)
      if let floor = state.unreadFloors[id], idle <= floor {
        // A view event at or below a deliberate unread mark or an undone read is stale.
        return .none
      }
      acknowledgeView(sessionID: id, idle: idle, state: &state)
      state.manuallyUnreadKeys.remove(key)
      state.unreadFloors[id] = nil
      _ = store.write(state.manuallyUnreadKeys, for: HomeSharedKeys.manuallyUnreadSessions)
      return .none
    case .sessionDeleted(let id):
      let deleted = state.sessions.first { $0.id == id }
      state.sessions.removeAll { $0.id == id }
      state.activeSessionIDs.remove(id)
      state.attentionSessionIDs.remove(id)
      state.recentDeletedIDs.insert(id)
      state.deletionTombstones[id] = state.refreshRequest
      state.pendingDeletions[id] = nil
      if let deleted { purgeLocalRecords(deleted, state: &state) }
      return .none
    case .sessionArchiveChanged(let id, true):
      state.sessions.removeAll { $0.id == id }
      state.activeSessionIDs.remove(id)
      state.attentionSessionIDs.remove(id)
      return .none
    case .executionStarted(let id):
      state.activeSessionIDs.insert(id)
      return .none
    case .executionEnded(let id):
      state.activeSessionIDs.remove(id)
      return startRefresh(&state, delay: .milliseconds(250))
    case .attentionChanged(let askedID):
      guard let askedID else { return attentionEffect(&state) }
      return resolveAttentionEvent(askedID, state: &state)
    case .projectUpdated(let project):
      if let index = state.projects.firstIndex(where: { $0.id == project.id }) {
        state.projects[index] = project
      } else {
        state.projects.append(project)
      }
      return .none
    default:
      return .none
    }
  }

  // MARK: Read state

  private func acknowledgeView(sessionID: String, idle: Int64, state: inout State) {
    if let index = state.sessions.firstIndex(where: { $0.id == sessionID }) {
      state.sessions[index].viewedMilliseconds = max(state.sessions[index].viewedMilliseconds ?? 0, idle)
    }
    if var search = state.search, let index = search.results.firstIndex(where: { $0.id == sessionID }) {
      search.results[index].viewedMilliseconds = max(search.results[index].viewedMilliseconds ?? 0, idle)
      state.search = search
    }
  }

  private func setViewed(sessionID: String, viewed: Int64?, state: inout State) {
    if let index = state.sessions.firstIndex(where: { $0.id == sessionID }) {
      state.sessions[index].viewedMilliseconds = viewed
    }
    if var search = state.search, let index = search.results.firstIndex(where: { $0.id == sessionID }) {
      search.results[index].viewedMilliseconds = viewed
      state.search = search
    }
  }

  @discardableResult
  private func markRead(_ session: OpenCodeSession, state: inout State) -> (backup: CatchUpState.ReadBackup?, effect: Effect<Action>) {
    let key = state.key(session.id)
    let backup = CatchUpState.ReadBackup(
      idleMilliseconds: session.idleMilliseconds,
      viewedMilliseconds: session.viewedMilliseconds,
      readDate: state.readDates[key],
      wasManuallyUnread: state.manuallyUnreadKeys.contains(key),
      unreadFloorMilliseconds: state.unreadFloors[session.id]
    )
    state.readDates[key] = max(state.readDates[key] ?? .distantPast, session.updatedAt)
    state.manuallyUnreadKeys.remove(key)
    state.unreadFloors[session.id] = nil
    if let idle = session.idleMilliseconds, idle > 0 {
      acknowledgeView(sessionID: session.id, idle: idle, state: &state)
    }
    _ = store.write(state.readDates, for: HomeSharedKeys.sessionReadDates)
    _ = store.write(state.manuallyUnreadKeys, for: HomeSharedKeys.manuallyUnreadSessions)
    guard let idle = session.idleMilliseconds, idle > 0 else {
      return (backup, .none)
    }
    let receiptID = uuid.uuid()
    state.readReceipts[session.id] = State.ReadReceipt(id: receiptID, idle: idle, backup: backup)
    let server = state.server
    let client = client
    let generation = state.generation
    let sessionID = session.id
    let effect = Effect<Action>.run { send in
      do {
        try await client.viewSession(server, sessionID, idle)
        await send(
          .readReceiptFinished(
            generation: generation,
            sessionID: sessionID,
            receiptID: receiptID,
            result: .success(true)
          )
        )
      } catch is CancellationError {
        return
      } catch let error as OpenCodeClientError {
        await send(
          .readReceiptFinished(
            generation: generation,
            sessionID: sessionID,
            receiptID: receiptID,
            result: .failure(error)
          )
        )
      } catch {
        await send(
          .readReceiptFinished(
            generation: generation,
            sessionID: sessionID,
            receiptID: receiptID,
            result: .failure(OpenCodeClientError(.unreachable))
          )
        )
      }
    }
    .cancellable(id: CancelID.readReceipt(session.id), cancelInFlight: true)
    return (backup, effect)
  }

  /// Acknowledges every row whose indicator is unread. Waiting rows keep their unread state and
  /// their request; a failed receipt restores that row's watermark. Receipts go four at a time.
  private func markAllRead(_ state: inout State) -> Effect<Action> {
    let unread = state.sessions.filter { state.indicator($0) == .unread }
    guard !unread.isEmpty else { return .none }
    haptics.play(.selection)
    var receipts: [(sessionID: String, idle: Int64)] = []
    for session in unread {
      let key = state.key(session.id)
      let backup = CatchUpState.ReadBackup(
        idleMilliseconds: session.idleMilliseconds,
        viewedMilliseconds: session.viewedMilliseconds,
        readDate: state.readDates[key],
        wasManuallyUnread: state.manuallyUnreadKeys.contains(key),
        unreadFloorMilliseconds: state.unreadFloors[session.id]
      )
      state.readDates[key] = max(state.readDates[key] ?? .distantPast, session.updatedAt)
      state.manuallyUnreadKeys.remove(key)
      state.unreadFloors[session.id] = nil
      if let idle = session.idleMilliseconds, idle > 0 {
        state.markAllReceipts[session.id] = backup
        acknowledgeView(sessionID: session.id, idle: idle, state: &state)
        receipts.append((session.id, idle))
      }
    }
    _ = store.write(state.readDates, for: HomeSharedKeys.sessionReadDates)
    _ = store.write(state.manuallyUnreadKeys, for: HomeSharedKeys.manuallyUnreadSessions)
    guard !receipts.isEmpty else { return .none }
    let server = state.server
    let client = client
    let generation = state.generation
    let allReceipts = receipts
    return .run { send in
      var index = 0
      while index < allReceipts.count {
        let end = min(index + 4, allReceipts.count)
        let batch = Array(allReceipts[index..<end])
        await withTaskGroup(of: (String, Int64, Bool).self) { group in
          for receipt in batch {
            group.addTask {
              do {
                try await client.viewSession(server, receipt.sessionID, receipt.idle)
                return (receipt.sessionID, receipt.idle, true)
              } catch is CancellationError {
                return (receipt.sessionID, receipt.idle, false)
              } catch {
                return (receipt.sessionID, receipt.idle, false)
              }
            }
          }
          for await (sessionID, idle, succeeded) in group {
            await send(
              .markAllReceiptFinished(
                generation: generation,
                sessionID: sessionID,
                idle: idle,
                succeeded: succeeded
              )
            )
          }
        }
        index = end
      }
    }
    .cancellable(id: CancelID.markAllReceipts)
  }

  private func markUnread(_ session: OpenCodeSession, state: inout State) {
    let key = state.key(session.id)
    state.readDates[key] = session.updatedAt.addingTimeInterval(-1)
    state.manuallyUnreadKeys.insert(key)
    state.unreadFloors[session.id] = session.idleMilliseconds ?? Int64.max
    state.readReceipts[session.id] = nil
    _ = store.write(state.readDates, for: HomeSharedKeys.sessionReadDates)
    _ = store.write(state.manuallyUnreadKeys, for: HomeSharedKeys.manuallyUnreadSessions)
  }

  private func restoreRead(_ backup: CatchUpState.ReadBackup, sessionID: String, state: inout State) {
    let key = state.key(sessionID)
    if let readDate = backup.readDate {
      state.readDates[key] = readDate
    } else {
      state.readDates[key] = nil
    }
    if backup.wasManuallyUnread {
      state.manuallyUnreadKeys.insert(key)
    } else {
      state.manuallyUnreadKeys.remove(key)
    }
    setViewed(sessionID: sessionID, viewed: backup.viewedMilliseconds, state: &state)
    if let floor = backup.unreadFloorMilliseconds {
      state.unreadFloors[sessionID] = floor
    } else {
      state.unreadFloors[sessionID] = nil
    }
    _ = store.write(state.readDates, for: HomeSharedKeys.sessionReadDates)
    _ = store.write(state.manuallyUnreadKeys, for: HomeSharedKeys.manuallyUnreadSessions)
  }

  // MARK: Search and paging

  private func reduceSearchChanged(_ text: String, state: inout State) -> Effect<Action> {
    state.searchText = text
    state.searchToken += 1
    let token = state.searchToken
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      state.search = nil
      return .merge(.cancel(id: CancelID.search), .cancel(id: CancelID.searchPage))
    }
    // With every page already loaded, the local filter answers and no socket is opened.
    if state.page.next == nil && !state.page.failed {
      state.search = nil
      return .merge(.cancel(id: CancelID.search), .cancel(id: CancelID.searchPage))
    }
    let kept = (state.search?.results ?? []).filter {
      $0.title.localizedCaseInsensitiveContains(query)
    }
    state.search = State.SearchState(query: query, results: kept, isLoading: true)
    return firstSearchEffect(
      server: state.server,
      generation: state.generation,
      query: query,
      token: token,
      delay: .milliseconds(250)
    )
  }

  /// Loads the next page, or retries the footer's failed page. The footer's Try Again is the same
  /// action: a failed search (first page or append) and a failed ordinary page each keep their
  /// cursor so the retry asks for exactly the page that failed.
  private func loadMore(_ state: inout State) -> Effect<Action> {
    if let search = state.search {
      guard !search.isLoading else { return .none }
      if search.failed {
        state.search?.failed = false
        state.search?.isLoading = true
        state.searchToken += 1
        let token = state.searchToken
        if let cursor = search.next {
          return searchPageEffect(
            server: state.server,
            generation: state.generation,
            query: search.query,
            token: token,
            cursor: cursor,
            appending: true
          )
        }
        return firstSearchEffect(
          server: state.server,
          generation: state.generation,
          query: search.query,
          token: token,
          delay: .zero
        )
      }
      guard let cursor = search.next else { return .none }
      state.search?.isLoading = true
      return searchPageEffect(
        server: state.server,
        generation: state.generation,
        query: search.query,
        token: state.searchToken,
        cursor: cursor,
        appending: true
      )
    }
    guard state.searchText.isEmpty else { return .none }
    if state.page.failed {
      guard let cursor = state.page.next else { return .none }
      state.page.failed = false
      state.page.isLoading = true
      return olderPageEffect(
        server: state.server,
        generation: state.generation,
        cursor: cursor
      )
    }
    guard let cursor = state.page.next, state.page.canLoad else { return .none }
    state.page.isLoading = true
    return olderPageEffect(
      server: state.server,
      generation: state.generation,
      cursor: cursor
    )
  }

  private func firstSearchEffect(
    server: OpenCodeServer,
    generation: Int,
    query: String,
    token: Int,
    delay: Duration
  ) -> Effect<Action> {
    let client = client
    let clock = clock
    return .run { send in
      do {
        if delay > .zero { try await clock.sleep(delay) }
        let page = try await client.sessionPage(server, .search(query), 50)
        await send(
          .searchLoaded(
            generation: generation,
            query: query,
            token: token,
            appending: false,
            result: .success(page)
          )
        )
      } catch is CancellationError {
        return
      } catch let error as OpenCodeClientError {
        await send(
          .searchLoaded(generation: generation, query: query, token: token, appending: false, result: .failure(error))
        )
      } catch {
        await send(
          .searchLoaded(
            generation: generation,
            query: query,
            token: token,
            appending: false,
            result: .failure(OpenCodeClientError(.unreachable))
          )
        )
      }
    }
    .cancellable(id: CancelID.search, cancelInFlight: true)
  }

  private func searchPageEffect(
    server: OpenCodeServer,
    generation: Int,
    query: String,
    token: Int,
    cursor: String,
    appending: Bool
  ) -> Effect<Action> {
    let client = client
    return .run { send in
      do {
        let page = try await client.sessionPage(server, .after(cursor), 50)
        await send(
          .searchLoaded(
            generation: generation,
            query: query,
            token: token,
            appending: appending,
            result: .success(page)
          )
        )
      } catch is CancellationError {
        return
      } catch let error as OpenCodeClientError {
        await send(
          .searchLoaded(
            generation: generation,
            query: query,
            token: token,
            appending: appending,
            result: .failure(error)
          )
        )
      } catch {
        await send(
          .searchLoaded(
            generation: generation,
            query: query,
            token: token,
            appending: appending,
            result: .failure(OpenCodeClientError(.unreachable))
          )
        )
      }
    }
    .cancellable(id: CancelID.searchPage, cancelInFlight: true)
  }

  private func olderPageEffect(
    server: OpenCodeServer,
    generation: Int,
    cursor: String
  ) -> Effect<Action> {
    let client = client
    return .run { send in
      do {
        let page = try await client.sessionPage(server, .after(cursor), 50)
        await send(.olderLoaded(generation: generation, cursor: cursor, result: .success(page)))
      } catch is CancellationError {
        return
      } catch let error as OpenCodeClientError {
        await send(.olderLoaded(generation: generation, cursor: cursor, result: .failure(error)))
      } catch {
        await send(.olderLoaded(generation: generation, cursor: cursor, result: .failure(OpenCodeClientError(.unreachable))))
      }
    }
    .cancellable(id: CancelID.olderPage, cancelInFlight: true)
  }

  // MARK: Deletion

  private func confirmDeletion(_ state: inout State) -> Effect<Action> {
    guard let pending = state.pendingDeletion else { return .none }
    let session = pending.session
    state.pendingDeletion = nil
    guard let index = state.sessions.firstIndex(where: { $0.id == session.id }) else {
      // A search-only row is not in the list; drop it from results and delete on the server.
      state.search?.results.removeAll { $0.id == session.id }
      state.recentDeletedIDs.insert(session.id)
      let backup = State.DeletionBackup(
        session: session,
        index: 0,
        wasActive: false,
        neededAttention: false,
        wasListed: false
      )
      let operationID = uuid.uuid()
      state.pendingDeletions[session.id] = State.PendingDeletion(
        backup: backup,
        operationID: operationID,
        isRunning: true,
        needsVerification: false
      )
      return deletionEffect(
        session: session,
        backup: backup,
        operationID: operationID,
        state: &state
      )
    }
    let backup = State.DeletionBackup(
      session: session,
      index: index,
      wasActive: state.activeSessionIDs.contains(session.id),
      neededAttention: state.attentionSessionIDs.contains(session.id)
    )
    state.sessions.remove(at: index)
    state.activeSessionIDs.remove(session.id)
    state.attentionSessionIDs.remove(session.id)
    state.search?.results.removeAll { $0.id == session.id }
    state.recentDeletedIDs.insert(session.id)
    let operationID = uuid.uuid()
    state.pendingDeletions[session.id] = State.PendingDeletion(
      backup: backup,
      operationID: operationID,
      isRunning: true,
      needsVerification: false
    )
    return deletionEffect(
      session: session,
      backup: backup,
      operationID: operationID,
      state: &state
    )
  }

  private func deletionEffect(
    session: OpenCodeSession,
    backup: State.DeletionBackup?,
    operationID: UUID,
    state: inout State
  ) -> Effect<Action> {
    let server = state.server
    let serverID = state.serverID
    let client = client
    return .run { send in
      do {
        try await client.deleteSession(server, session.id)
        await send(
          .deletionFinished(
            serverID: serverID,
            sessionID: session.id,
            operationID: operationID,
            result: .success(true)
          )
        )
      } catch is CancellationError {
        return
      } catch let error as OpenCodeClientError {
        await send(
          .deletionFinished(
            serverID: serverID,
            sessionID: session.id,
            operationID: operationID,
            result: .failure(error)
          )
        )
      } catch {
        await send(
          .deletionFinished(
            serverID: serverID,
            sessionID: session.id,
            operationID: operationID,
            result: .failure(OpenCodeClientError(.unreachable))
          )
        )
      }
    }
    .cancellable(id: CancelID.deletion(session.id), cancelInFlight: true)
  }

  private func restoreDeletion(_ backup: State.DeletionBackup, state: inout State) {
    state.recentDeletedIDs.remove(backup.session.id)
    if !backup.wasListed {
      if !(state.search?.results.contains(where: { $0.id == backup.session.id }) ?? false) {
        state.search?.results.append(backup.session)
      }
      return
    }
    guard !state.sessions.contains(where: { $0.id == backup.session.id }) else { return }
    let index = min(backup.index, state.sessions.count)
    state.sessions.insert(backup.session, at: index)
    if backup.wasActive { state.activeSessionIDs.insert(backup.session.id) }
    if backup.neededAttention { state.attentionSessionIDs.insert(backup.session.id) }
  }

  private func confirmDeleted(_ backup: State.DeletionBackup, state: inout State) {
    purgeLocalRecords(backup.session, state: &state)
    state.recentDeletedIDs.insert(backup.session.id)
    state.deletionTombstones[backup.session.id] = state.refreshRequest
    trimDeletionTombstones(&state)
  }

  private func trimDeletionTombstones(_ state: inout State) {
    guard state.deletionTombstones.count > 200 else { return }
    let oldest = state.deletionTombstones.min { $0.value < $1.value }?.key
    if let oldest { state.deletionTombstones[oldest] = nil }
  }

  private enum DeletionFailureKind {
    case confirmed
    case failed
    case uncertain
  }

  /// A 404 (other than a missing location) says the session is gone; a 4xx says the request was
  /// refused; transport timeouts and 5xx leave the server outcome unknown.
  private func deletionFailureKind(_ error: OpenCodeClientError) -> DeletionFailureKind {
    if let status = error.statusCode {
      if status == 404 { return error.isLocationMissing ? .uncertain : .confirmed }
      if (400...499).contains(status), status != 408, status != 429 { return .failed }
      return .uncertain
    }
    switch error.failure {
    case .transport(.notSent), .invalidURL, .unsupported:
      return .failed
    default:
      return .uncertain
    }
  }

  private func noticeExpiryEffect() -> Effect<Action> {
    let clock = clock
    return .run { send in
      try? await clock.sleep(.seconds(5))
      await send(.noticeExpired)
    }
    .cancellable(id: CancelID.notice, cancelInFlight: true)
  }

  /// On reconnect every unsettled delete gets one targeted session read. First-page presence or
  /// absence is never used; an older session can simply be on a later page.
  private func verifyPendingDeletions(_ state: inout State) -> Effect<Action> {
    guard !state.isPinned else { return .none }
    let pending = state.pendingDeletions
      .filter { $0.value.needsVerification || $0.value.isRunning }
      .prefix(8)
    var effects: [Effect<Action>] = []
    for (sessionID, deletion) in pending {
      state.pendingDeletions[sessionID]?.needsVerification = true
      effects.append(
        verifyDeletion(
          server: state.server,
          serverID: state.serverID,
          generation: state.generation,
          sessionID: sessionID,
          operationID: deletion.operationID
        )
      )
    }
    return effects.isEmpty ? .none : .merge(effects)
  }

  private func verifyDeletion(
    server: OpenCodeServer,
    serverID: String,
    generation: Int,
    sessionID: String,
    operationID: UUID
  ) -> Effect<Action> {
    let client = client
    return .run { send in
      let outcome: DeletionVerification
      do {
        _ = try await client.getSession(server, sessionID)
        outcome = .present
      } catch is CancellationError {
        return
      } catch let error as OpenCodeClientError {
        if error.statusCode == 404, !error.isLocationMissing {
          outcome = .absent
        } else {
          outcome = .inconclusive(error)
        }
      } catch {
        outcome = .inconclusive(OpenCodeClientError(.unreachable))
      }
      await send(
        .deletionVerified(
          generation: generation,
          serverID: serverID,
          sessionID: sessionID,
          operationID: operationID,
          outcome: outcome
        )
      )
    }
    .cancellable(id: CancelID.deletionVerification(sessionID), cancelInFlight: true)
  }

  /// A confirmed server delete also drops this phone's records for the session.
  private func purgeLocalRecords(_ session: OpenCodeSession, state: inout State) {
    let key = state.key(session.id)
    state.pinnedKeys.removeAll { $0 == key }
    state.readDates[key] = nil
    state.manuallyUnreadKeys.remove(key)
    state.mutedKeys.remove(key)
    state.hiddenKeys.remove(key)
    _ = store.write(state.pinnedKeys, for: HomeSharedKeys.pinnedSessions)
    _ = store.write(state.readDates, for: HomeSharedKeys.sessionReadDates)
    _ = store.write(state.manuallyUnreadKeys, for: HomeSharedKeys.manuallyUnreadSessions)
    _ = store.write(state.mutedKeys, for: HomeSharedKeys.mutedSessions)
    _ = store.write(state.hiddenKeys, for: HomeSharedKeys.hiddenSessions)
  }

  // MARK: Catch Up

  /// Follows reads, answers and new activity while the stack is open. The front card stays until
  /// the reader moves it along.
  private func reconcileCatchUp(_ state: inout State) {
    if state.catchUp == nil, !state.catchUpSessions.isEmpty { state.catchUpFinished = false }
    guard var catchUp = state.catchUp else { return }
    let candidates = state.catchUpSessions
    let front = catchUp.queue.first
    var queue = catchUp.queue.filter { id in
      if id == front { return true }
      guard let session = state.session(id) else { return false }
      return state.needsCatchUp(session)
    }
    let queued = Set(queue)
    let handled = Dictionary(catchUp.handled.map { ($0.sessionID, $0) }, uniquingKeysWith: { _, last in last })
    for candidate in candidates where !queued.contains(candidate.id) {
      if let past = handled[candidate.id],
        !past.isSuperseded(
          by: candidate,
          needsAttention: state.attentionSessionIDs.contains(candidate.id)
        )
      {
        continue
      }
      queue.append(candidate.id)
    }
    catchUp.queue = queue
    state.catchUp = catchUp
    if !catchUp.queue.isEmpty || !candidates.isEmpty { state.catchUpFinished = false }
  }

  private func dismissCatchUpCard(
    sessionID: String,
    disposition: CatchUpDisposition,
    state: inout State
  ) -> Effect<Action> {
    guard var catchUp = state.catchUp, catchUp.queue.first == sessionID else { return .none }
    guard let session = state.session(sessionID) else { return .none }
    let neededAttention = state.attentionSessionIDs.contains(sessionID)
    var effect: Effect<Action> = .none
    var backup: CatchUpState.ReadBackup?
    if disposition == .markRead {
      let read = markRead(session, state: &state)
      backup = read.backup
      effect = read.effect
    }
    catchUp.queue.removeFirst()
    catchUp.handled.append(
      CatchUpState.Handled(
        sessionID: sessionID,
        disposition: disposition,
        idleMilliseconds: session.idleMilliseconds,
        updatedAt: session.updatedAt,
        neededAttention: neededAttention
      )
    )
    catchUp.lastUndo = CatchUpState.Undo(
      sessionID: sessionID,
      disposition: disposition,
      backup: backup
    )
    catchUp.problem = nil
    if catchUp.queue.isEmpty {
      state.catchUp = nil
      state.catchUpFinished = true
      state.isDrawerOpen = true
    } else {
      state.catchUp = catchUp
    }
    return effect
  }

  private func undoLastCatchUpCard(_ state: inout State) -> Effect<Action> {
    guard var catchUp = state.catchUp, let undo = catchUp.lastUndo else { return .none }
    if let backup = undo.backup {
      restoreRead(backup, sessionID: undo.sessionID, state: &state)
      if let session = state.session(undo.sessionID), state.isUnread(session) {
        state.unreadFloors[undo.sessionID] = max(
          state.unreadFloors[undo.sessionID] ?? 0,
          backup.idleMilliseconds ?? 0
        )
      }
      state.readReceipts[undo.sessionID] = nil
    }
    catchUp.handled.removeAll { $0.sessionID == undo.sessionID }
    catchUp.queue.removeAll { $0 == undo.sessionID }
    catchUp.queue.insert(undo.sessionID, at: 0)
    catchUp.lastUndo = nil
    catchUp.problem = nil
    state.catchUp = catchUp
    return .cancel(id: CancelID.readReceipt(undo.sessionID))
  }

  // MARK: What's New

  private func markWhatsNewSeen(_ state: inout State) {
    let ids = Set(state.whatsNewEntries.map(\.id))
    guard !ids.isSubset(of: state.whatsNew.seenIDs) else { return }
    state.whatsNew.seenIDs.formUnion(ids)
    _ = store.write(state.whatsNew.seenIDs, for: HomeSharedKeys.whatsNewSeen)
  }

  // MARK: Cancellation

  private func cancelServerWork() -> Effect<Action> {
    .merge(
      .cancel(id: CancelID.refresh),
      .cancel(id: CancelID.attention),
      .cancel(id: CancelID.olderPage),
      .cancel(id: CancelID.search),
      .cancel(id: CancelID.searchPage),
      .cancel(id: CancelID.cache),
      .cancel(id: CancelID.snapshotWrite),
      .cancel(id: CancelID.notice)
    )
  }
}
