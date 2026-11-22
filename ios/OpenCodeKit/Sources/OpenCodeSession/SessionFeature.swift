import ComposableArchitecture
import Foundation
import OpenCodeCore
import OpenCodeServer

/// One session screen: authoritative reads, the run's Stop, the family's subagents, pending
/// permission/form requests and the shell/background panel. Transcript rows and composer editing
/// belong to P8/P9; this feature keeps their state boundaries but does not claim them.
@Reducer
public struct SessionFeature: Sendable {
  @ObservableState
  public struct State: Equatable, Sendable, Identifiable {
    public let id: Int
    public var server: OpenCodeServer
    public var selection: SessionSelection
    public var root: OpenCodeSession?
    public var family: SessionFamily?
    public var pages: [SessionPage]
    public var isLive: Bool
    public var isLoading: Bool
    public var loadProblem: SessionProblem?
    public var run: SessionRun
    public var requests: SessionRequests
    public var background: SessionBackground
    public var pendingInputs: [PendingInput]
    public var notice: SessionNotice?
    public var isPinned: Bool

    public var refresh: SessionRefresh?
    var nextRefreshID: Int
    var nextPageID: Int
    var selectionByPage: [Int: String?]
    var didStart: Bool

    public init(
      id: Int,
      server: OpenCodeServer,
      selection: SessionSelection,
      session: OpenCodeSession? = nil,
      isLive: Bool = true,
      isPinned: Bool = false
    ) {
      self.id = id
      self.server = server
      self.selection = selection
      self.root = session
      self.family = session.map { SessionFamily(root: $0, sessions: [$0]) }
      self.pages = []
      self.isLive = isLive
      self.isLoading = session == nil
      self.loadProblem = nil
      self.run = SessionRun()
      self.requests = SessionRequests()
      self.background = SessionBackground()
      self.pendingInputs = []
      self.notice = nil
      self.isPinned = isPinned
      self.refresh = nil
      self.nextRefreshID = 0
      self.nextPageID = 1
      self.selectionByPage = [0: nil]
      self.didStart = false
    }

    /// Effect bookkeeping (read ids, page ids, run generation) stays outside equality; every value
    /// a surface renders is included.
    public static func == (lhs: State, rhs: State) -> Bool {
      lhs.id == rhs.id
        && lhs.server == rhs.server
        && lhs.selection == rhs.selection
        && lhs.root == rhs.root
        && lhs.family == rhs.family
        && lhs.pages == rhs.pages
        && lhs.isLive == rhs.isLive
        && lhs.isLoading == rhs.isLoading
        && lhs.loadProblem == rhs.loadProblem
        && lhs.run.isRunning == rhs.run.isRunning
        && lhs.run.isInterrupting == rhs.run.isInterrupting
        && lhs.run.stopAttempt == rhs.run.stopAttempt
        && lhs.requests == rhs.requests
        && lhs.background == rhs.background
        && lhs.pendingInputs == rhs.pendingInputs
        && lhs.notice == rhs.notice
        && lhs.isPinned == rhs.isPinned
    }

    // MARK: Derived

    public var activePage: SessionPage? { pages.last }

    public var activeSessionID: String? {
      activePage?.sessionID ?? root?.id
    }

    public var activeSession: OpenCodeSession? {
      guard let id = activeSessionID else { return nil }
      return family?.session(id) ?? (root?.id == id ? root : nil)
    }

    public var title: String { activeSession?.title ?? root?.title ?? "Session" }

    public var isAtRoot: Bool { pages.isEmpty }

    public var subagents: [OpenCodeSession] { family?.subagents ?? [] }

    public var isRunning: Bool { run.isRunning }

    public var canInterrupt: Bool { isRunning && !run.isInterrupting && isLive }

    public var activeRequests: SessionRequests { requests }

    public var hasBackgroundWork: Bool { background.isWorking }

    public var backgroundSummary: (subagents: Int, shells: Int, jobs: Int) {
      (subagents.filter { family?.isActive($0.id) == true }.count, background.shells.count, background.jobs.count)
    }

    public func pageTitle(_ page: SessionPage) -> String {
      family?.session(page.sessionID)?.title ?? page.title
    }
  }

  public enum Action: Equatable, Sendable {
    case task
    case refreshRequested(RefreshReason)
    case refreshFinished(
      sessionID: String,
      requestID: Int,
      result: Result<SessionSnapshot, OpenCodeClientError>
    )
    case retryTapped
    case connectionChanged(isConnected: Bool)
    case connectionResynchronized
    case serverEvent(ServerEvent)
    case pendingInputsLoaded(sessionID: String, result: Result<[PendingInput], OpenCodeClientError>)

    case openSubagent(String)
    case popPage
    case popToRoot

    case interruptTapped
    case interruptAcknowledged(sessionID: String, generation: Int, interrupted: Bool)
    case interruptFailed(sessionID: String, generation: Int)
    case interruptResumed(sessionID: String, generation: Int)
    case runStateRead(sessionID: String, generation: Int, isActive: Bool)
    case strandedSteerTapped(inputID: String)
    case strandedSteerFinished(sessionID: String, generation: Int, inputID: String, result: Result<Bool, OpenCodeClientError>)

    case requestSelected(String?)
    case requestValueChanged(formID: String, key: String, value: FormValue?)
    case permissionReplyTapped(id: String, decision: PermissionDecision, message: String?)
    case formSubmitTapped(String)
    case formCancelTapped(String)
    case permissionReplyFinished(
      requestID: String,
      sessionID: String,
      result: Result<Bool, OpenCodeClientError>
    )
    case formReplyFinished(
      requestID: String,
      sessionID: String,
      dismissal: Bool,
      result: Result<FormReplyOutcome, OpenCodeClientError>
    )
    case requestLoadRetried

    case backgroundTapped
    case backgroundDismissed
    case shellOutputTapped(shellID: String)
    case shellOutputAppeared
    case shellOutputDisappeared
    case shellOutputTick
    case shellOutputLoaded(shellID: String, result: Result<ShellOutputPage, OpenCodeClientError>)
    case shellOutputPrepared(shellID: String, start: Int, result: Result<ShellOutputPage, OpenCodeClientError>)
    case shellEarlierTapped
    case shellEarlierLoaded(shellID: String, start: Int, result: Result<ShellOutputPage, OpenCodeClientError>)
    case shellStopTapped
    case shellStopConfirmed
    case shellOutputExited(String)
    case shellStopFinished(shellID: String, error: OpenCodeClientError?)
    case jobCancelTapped(jobID: String)
    case jobCancelFinished(jobID: String, error: OpenCodeClientError?)
    case backgroundProblemDismissed

    case noticeDismissed
    case delegate(Delegate)
  }

  public enum Delegate: Equatable, Sendable {
    case dismiss
  }

  enum CancelID: Hashable {
    case refresh
    case requests
    case pendingInputs
    case interrupt(Int)
    case interruptSettle(Int)
    case runEndCheck(Int)
    case strandedSteer(Int)
    case shellOutput(String)
    case shellPoll(String)
    case shellEarlier(String)
    case shellStop(String)
    case job(String)
    case notice
  }

  @Dependency(\.openCodeClient) private var client
  @Dependency(\.clock) private var clock
  @Dependency(\.networkPath) private var networkPath
  @Dependency(\.haptics) private var haptics

  public init() {}

  public var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        guard !state.didStart else { return .none }
        state.didStart = true
        guard !state.isPinned else { return .none }
        return requestRefresh(.open, state: &state)

      case .refreshRequested(let reason):
        guard !state.isPinned else { return .none }
        return requestRefresh(reason, state: &state)

      case .refreshFinished(let sessionID, let requestID, let result):
        return refreshFinished(
          sessionID: sessionID,
          requestID: requestID,
          result: result,
          state: &state
        )

      case .retryTapped:
        return requestRefresh(.open, state: &state)

      case .connectionChanged(let isConnected):
        let wasLive = state.isLive
        state.isLive = isConnected
        if isConnected {
          guard !wasLive, state.root != nil else { return .none }
          return requestRefresh(.reconnect, state: &state)
        }
        state.refresh = nil
        state.nextRefreshID += 1
        return .merge(
          .cancel(id: CancelID.refresh),
          .cancel(id: CancelID.requests),
          .cancel(id: CancelID.pendingInputs),
          .cancel(id: CancelID.shellPoll(state.background.output?.shellID ?? "")),
          .cancel(id: CancelID.interruptSettle(state.run.generation)),
          .cancel(id: CancelID.runEndCheck(state.run.generation))
        )

      case .connectionResynchronized:
        guard state.isLive else { return .none }
        return requestRefresh(.reconnect, state: &state)

      case .serverEvent(let event):
        guard state.isLive else { return .none }
        return receive(event, state: &state)

      case .pendingInputsLoaded(let sessionID, let result):
        guard sessionID == state.activeSessionID else { return .none }
        if case .success(let inputs) = result {
          state.pendingInputs = inputs
        }
        return .none

      case .openSubagent(let sessionID):
        return openSubagent(sessionID, state: &state)

      case .popPage:
        return popPage(state: &state)

      case .popToRoot:
        guard !state.pages.isEmpty else { return .none }
        state.pages.removeAll()
        restoreSelection(pageID: 0, state: &state)
        state.isLoading = true
        let abandon = abandonRefresh(&state)
        return .merge(abandon, requestRefresh(.resume, state: &state))

      case .interruptTapped:
        return interruptTapped(&state)

      case .interruptAcknowledged(let sessionID, let generation, let interrupted):
        guard sessionID == state.activeSessionID,
          generation == state.run.generation,
          state.run.isInterrupting
        else { return .none }
        if interrupted || state.run.isRunning {
          state.run.stopAttempt?.acknowledged = true
          return settleStop(readingAtOnce: !interrupted, state: state)
        }
        _ = supersedeRunWork(&state)
        if state.run.isRunning {
          return confirmRunState(after: .milliseconds(1_500), state: state)
        }
        return .none

      case .interruptFailed(let sessionID, let generation):
        guard sessionID == state.activeSessionID, generation == state.run.generation else {
          return .none
        }
        haptics.play(.error)
        state.run.isInterrupting = false
        state.run.stopAttempt = nil
        state.notice = .couldNotInterrupt
        return noticeExpiry()

      case .interruptResumed(let sessionID, let generation):
        guard sessionID == state.activeSessionID, generation == state.run.generation else {
          return .none
        }
        _ = supersedeRunWork(&state)
        state.run.isRunning = true
        haptics.play(.success)
        return .merge(
          requestRefresh(.runState, state: &state),
          fetchPendingInputs(server: state.server, sessionID: sessionID)
        )

      case .runStateRead(let sessionID, let generation, let isActive):
        guard sessionID == state.activeSessionID, generation == state.run.generation else {
          return .none
        }
        state.run.isRunning = isActive
        if !isActive {
          state.run.isInterrupting = false
          state.run.stopAttempt = nil
        }
        return .none

      case .strandedSteerTapped(let inputID):
        return strandedSteer(inputID: inputID, state: &state)

      case .strandedSteerFinished(let sessionID, let generation, let inputID, let result):
        guard sessionID == state.activeSessionID, generation == state.run.generation else {
          return .none
        }
        switch result {
        case .success:
          return fetchPendingInputs(server: state.server, sessionID: sessionID)
        case .failure:
          haptics.play(.error)
          state.notice = .couldNotWakeInput
          return .merge(fetchPendingInputs(server: state.server, sessionID: sessionID), noticeExpiry())
        }

      case .requestSelected(let id):
        state.requests.selectedID = id
        state.selectionByPage[state.activePage?.id ?? 0] = id
        return .none

      case .requestValueChanged(let formID, let key, let value):
        guard state.requests.form(formID) != nil,
          !state.requests.completedIDs.contains(formID),
          !state.requests.respondingIDs.contains(formID)
        else { return .none }
        var answers = state.requests.answers[formID] ?? [:]
        answers[key] = value
        state.requests.answers[formID] = answers
        if case .validation = state.requests.failures[formID] {
          state.requests.failures[formID] = nil
        }
        return .none

      case .permissionReplyTapped(let id, let decision, let message):
        return replyPermission(id: id, decision: decision, message: message, state: &state)

      case .formSubmitTapped(let id):
        return submitForm(id, state: &state)

      case .formCancelTapped(let id):
        return cancelForm(id, state: &state)

      case .permissionReplyFinished(let requestID, let sessionID, let result):
        guard state.requests.respondingIDs.remove(requestID) != nil else { return .none }
        switch result {
        case .success:
          haptics.play(.success)
          AppLog(category: .app).event(.requestReplied, [LogField("form", .flag(false))])
          state.requests.completedIDs.insert(requestID)
          pruneRequest(requestID, state: &state)
        case .failure:
          haptics.play(.error)
          state.requests.failures[requestID] = .reply
        }
        if state.requests.permission(requestID) != nil { state.requests.selectedID = requestID }
        return requestRefresh(.invalidation, state: &state)

      case .formReplyFinished(let requestID, let sessionID, let dismissal, let result):
        guard state.requests.respondingIDs.remove(requestID) != nil else { return .none }
        switch result {
        case .success(.settled):
          haptics.play(.success)
          AppLog(category: .app).event(.requestReplied, [LogField("form", .flag(true))])
          state.requests.completedIDs.insert(requestID)
          pruneRequest(requestID, state: &state)
        case .success(.conflict(let conflict)):
          haptics.play(.error)
          state.requests.completedIDs.insert(requestID)
          state.requests.failures[requestID] = .conflict(conflict)
          pruneRequest(requestID, state: &state)
          state.notice = .couldNotLoadRequests(.notFound)
        case .failure:
          haptics.play(.error)
          state.requests.failures[requestID] = dismissal ? .dismissal : .reply
        }
        return requestRefresh(.invalidation, state: &state)

      case .requestLoadRetried:
        state.requests.loadProblem = nil
        return requestRefresh(.invalidation, state: &state)

      case .backgroundTapped:
        state.background.isPresented = true
        state.background.problem = nil
        return requestRefresh(.watchdog, state: &state)

      case .backgroundDismissed:
        let shellID = state.background.output?.shellID
        state.background.isPresented = false
        state.background.output = nil
        guard let shellID else { return .none }
        return .merge(
          .cancel(id: CancelID.shellPoll(shellID)),
          .cancel(id: CancelID.shellOutput(shellID))
        )

      case .shellOutputTapped(let shellID):
        guard let shell = state.background.shells.first(where: { $0.id == shellID }) else {
          return .none
        }
        state.background.output = ShellOutputState(shellID: shellID, title: shell.title)
        return loadShellTail(shellID: shellID, state: state)

      case .shellOutputAppeared:
        guard let output = state.background.output, !output.isUnavailable else { return .none }
        return pollShell(shellID: output.shellID, state: state)

      case .shellOutputDisappeared:
        guard let output = state.background.output else { return .none }
        return .cancel(id: CancelID.shellPoll(output.shellID))

      case .shellOutputTick:
        guard let output = state.background.output, !output.isUnavailable, !output.isStopping
        else { return .none }
        return pollShell(shellID: output.shellID, state: state)

      case .shellOutputPrepared(let shellID, let start, let result):
        guard var output = state.background.output, output.shellID == shellID else { return .none }
        switch result {
        case .success(let page):
          output.output = page.output
          output.startCursor = start
          output.endCursor = page.cursor
          output.size = page.size
          output.problem = nil
          output.isUnavailable = false
        case .failure(let error):
          if error.statusCode == 404 {
            output.isUnavailable = true
            output.endCursor = output.endCursor ?? 0
          } else {
            output.problem = .from(error, isOffline: !state.isLive)
          }
        }
        state.background.output = output
        return .none

      case .shellOutputLoaded(let shellID, let result):
        guard var output = state.background.output, output.shellID == shellID else { return .none }
        switch result {
        case .success(let page):
          let end = output.endCursor
          guard end != nil, page.cursor > end! else { return .none }
          output.output = trimShellOutput(output.output + page.output, limit: output.retainLimit)
          output.endCursor = page.cursor
          output.size = page.size
          output.problem = nil
          state.background.output = output
        case .failure(let error):
          if error.statusCode == 404 {
            output.isUnavailable = true
          } else {
            output.problem = .from(error, isOffline: !state.isLive)
          }
          state.background.output = output
        }
        return .none

      case .shellOutputExited(let shellID):
        guard var output = state.background.output, output.shellID == shellID else {
          return .none
        }
        output.isRunning = false
        state.background.output = output
        return .none

      case .shellEarlierTapped:
        return loadEarlierShellOutput(state: &state)

      case .shellEarlierLoaded(let shellID, let start, let result):
        guard var output = state.background.output, output.shellID == shellID else { return .none }
        output.isLoadingEarlier = false
        switch result {
        case .success(let page):
          guard page.cursor == output.startCursor, start < output.startCursor else {
            state.background.output = output
            return .none
          }
          output.output = trimShellOutput(page.output + output.output, limit: max(output.retainLimit, output.output.utf8.count + page.output.utf8.count))
          output.startCursor = start
          output.retainLimit = min(
            ShellOutputState.maximumRetainedBytes,
            max(output.retainLimit, output.output.utf8.count)
          )
          state.background.output = output
        case .failure(let error):
          if error.statusCode == 404 {
            output.isUnavailable = true
          } else {
            output.problem = .from(error, isOffline: !state.isLive)
          }
          state.background.output = output
        }
        return .none

      case .shellStopTapped:
        guard var output = state.background.output, !output.isUnavailable, !output.isStopping
        else { return .none }
        output.isStopping = true
        state.background.output = output
        return .none

      case .shellStopConfirmed:
        return stopShell(state: &state)

      case .shellStopFinished(let shellID, let error):
        guard var output = state.background.output, output.shellID == shellID else { return .none }
        output.isStopping = false
        if let error, error.statusCode != 404 {
          haptics.play(.error)
          output.problem = .from(error, isOffline: !state.isLive)
          state.background.output = output
          return pollShell(shellID: shellID, state: state)
        }
        output.isUnavailable = true
        state.background.output = output
        state.background.shells.removeAll { $0.id == shellID }
        return .none

      case .jobCancelTapped(let jobID):
        guard !state.background.stoppingIDs.contains(jobID) else { return .none }
        state.background.stoppingIDs.insert(jobID)
        let client = client
        let server = state.server
        return .run { send in
          do {
            try await client.cancelJob(server, jobID)
            await send(.jobCancelFinished(jobID: jobID, error: nil))
          } catch is CancellationError {
            return
          } catch let error as OpenCodeClientError {
            await send(.jobCancelFinished(jobID: jobID, error: error))
          } catch {
            await send(.jobCancelFinished(jobID: jobID, error: OpenCodeClientError(.unreachable)))
          }
        }
        .cancellable(id: CancelID.job(jobID), cancelInFlight: true)

      case .jobCancelFinished(let jobID, let error):
        state.background.stoppingIDs.remove(jobID)
        if let error {
          haptics.play(.error)
          state.background.problem = .from(error, isOffline: !state.isLive)
        } else {
          state.background.jobs.removeAll { $0.id == jobID }
        }
        return .none

      case .backgroundProblemDismissed:
        state.background.problem = nil
        return .none

      case .noticeDismissed:
        state.notice = nil
        return .none

      case .delegate:
        return .none
      }
    }
  }
}

// MARK: - Snapshot

/// One authoritative read of the open session: metadata, family, requests and background work.
public struct SessionSnapshot: Equatable, Sendable {
  public var session: OpenCodeSession
  public var family: Result<SessionFamily, OpenCodeClientError>?
  public var requests: Result<PendingRequests, OpenCodeClientError>?
  public var isActive: Bool?
  public var shells: [ServerShell]?
  public var jobs: [ServerJob]?
  public var pendingInputs: [PendingInput]?

  public init(
    session: OpenCodeSession,
    family: Result<SessionFamily, OpenCodeClientError>? = nil,
    requests: Result<PendingRequests, OpenCodeClientError>? = nil,
    isActive: Bool? = nil,
    shells: [ServerShell]? = nil,
    jobs: [ServerJob]? = nil,
    pendingInputs: [PendingInput]? = nil
  ) {
    self.session = session
    self.family = family
    self.requests = requests
    self.isActive = isActive
    self.shells = shells
    self.jobs = jobs
    self.pendingInputs = pendingInputs
  }
}

extension SessionFeature {
  // MARK: Refresh

  private func requestRefresh(_ reason: RefreshReason, state: inout State) -> Effect<Action> {
    guard state.isLive, !state.isPinned else { return .none }
    guard let sessionID = state.activeSessionID ?? Optional(state.selection.sessionID) else {
      return .none
    }

    if var inFlight = state.refresh {
      if inFlight.followup == .runState { return .none }
      if inFlight.reason == .runState, reason == .runState, inFlight.followup == nil {
        return .none
      }
      if case .settlement(let requested) = reason,
        case .settlement(let running) = inFlight.reason,
        requested == running
      {
        return .none
      }
      if reason.messageID != nil, let followup = inFlight.followup, followup.messageID == nil {
        return .none
      }
      if case .settlement = inFlight.reason {
        inFlight.followup = reason
        state.refresh = inFlight
        return .none
      }
      if reason.requiresFollowup {
        inFlight.followup = reason
        state.refresh = inFlight
      }
      return .none
    }

    let requestID = state.nextRefreshID + 1
    state.nextRefreshID = requestID
    state.refresh = SessionRefresh(id: requestID, reason: reason)
    if state.root == nil { state.isLoading = true }
    return refreshEffect(
      server: state.server,
      sessionID: sessionID,
      requestID: requestID,
      reason: reason,
      knownFamily: state.family?.sessions.map(\.id) ?? []
    )
  }

  private func refreshEffect(
    server: OpenCodeServer,
    sessionID: String,
    requestID: Int,
    reason: RefreshReason,
    knownFamily: [String]
  ) -> Effect<Action> {
    let client = client
    let clock = clock
    let full = reason.readsFamily
    return .run { send in
      if reason.messageID != nil {
        do { try await clock.sleep(.milliseconds(200)) } catch { return }
      }
      let sessionResult = await capture { try await client.getSession(server, sessionID) }
      let session: OpenCodeSession
      switch sessionResult {
      case .success(let value): session = value
      case .failure(let error):
        await send(
          .refreshFinished(sessionID: sessionID, requestID: requestID, result: .failure(error))
        )
        return
      }

      var family: Result<SessionFamily, OpenCodeClientError>?
      if full {
        family = await capture { try await client.sessionFamily(server, session) }
      }
      let familyIDs = (try? family?.get())?.sessions.map(\.id) ?? knownFamily

      async let requests = capture {
        try await client.pendingRequests(server, session, familyIDs)
      }
      async let active = capture { try await client.sessionIsActive(server, sessionID) }
      async let shells: Result<[ServerShell], OpenCodeClientError>? =
        full ? capture { try await client.runningShells(server, session.directory) } : nil
      async let jobs: Result<[ServerJob], OpenCodeClientError>? =
        full ? capture { try await client.runningJobs(server, session.id) } : nil
      async let inputs: Result<[PendingInput], OpenCodeClientError>? = capture {
        try await client.pendingInputs(server, sessionID)
      }

      let snapshot = SessionSnapshot(
        session: session,
        family: family,
        requests: await requests,
        isActive: try? await active.get(),
        shells: try? await shells?.get(),
        jobs: try? await jobs?.get(),
        pendingInputs: try? await inputs?.get()
      )
      await send(
        .refreshFinished(sessionID: sessionID, requestID: requestID, result: .success(snapshot))
      )
    }
    .cancellable(id: CancelID.refresh)
  }

  private func refreshFinished(
    sessionID: String,
    requestID: Int,
    result: Result<SessionSnapshot, OpenCodeClientError>,
    state: inout State
  ) -> Effect<Action> {
    guard let inFlight = state.refresh, inFlight.id == requestID else { return .none }
    guard state.activeSessionID == sessionID || state.root?.id == sessionID else {
      state.refresh = nil
      return .none
    }

    switch result {
    case .failure(let error):
      state.refresh = nil
      state.isLoading = false
      AppLog(category: .app).event(
        .sessionRefreshFailed,
        [LogField("status", .status(error.statusCode ?? 0))]
      )
      apply(raced: inFlight.racedEvents, state: &state)
      if state.root == nil {
        state.loadProblem = .from(error, isOffline: !state.isLive)
      } else {
        state.notice = .couldNotRefresh(.from(error, isOffline: !state.isLive))
      }
      return .none
    case .success(let snapshot):
      state.refresh = nil
      state.isLoading = false
      state.loadProblem = nil
      state.notice = nil
      apply(snapshot: snapshot, for: sessionID, state: &state)
      apply(raced: inFlight.racedEvents, state: &state)
      AppLog(category: .app).event(
        .sessionRefreshed,
        [
          LogField("family", .count(state.family?.sessions.count ?? 0)),
          LogField("requests", .count(state.requests.reviewIDs.count)),
          LogField("shells", .count(state.background.shells.count)),
        ]
      )
      var followup = inFlight.followup
      if inFlight.racedEvents.contains(where: { event in
        switch event {
        case .executionStarted, .executionEnded, .attentionChanged: true
        default: false
        }
      }) {
        followup = followup == .runState ? .runState : (followup ?? .runState)
      }
      return followup.map { .send(.refreshRequested($0)) } ?? .none
    }
  }

  private func apply(snapshot: SessionSnapshot, for sessionID: String, state: inout State) {
    if state.root?.id == sessionID || state.root == nil {
      state.root = snapshot.session
    }
    state.family = mergedFamily(snapshot.family, rootSession: snapshot.session, state: state)
    if let family = state.family, let session = family.session(sessionID) {
      if state.root?.id == sessionID { state.root = session }
      if let index = state.pages.firstIndex(where: { $0.sessionID == sessionID }) {
        state.pages[index].title = session.title
      }
    }

    if let requests = snapshot.requests {
      switch requests {
      case .success(let pending):
        reconcile(requests: pending, state: &state)
      case .failure(let error):
        state.requests.loadProblem = .from(error, isOffline: !state.isLive)
      }
    }
    if case .failure(let error)? = snapshot.family {
      state.notice = .couldNotLoadFamily(.from(error, isOffline: !state.isLive))
    }

    if let isActive = snapshot.isActive {
      if let root = state.root, root.id == sessionID {
        state.run.isRunning = isActive
      } else if let family = state.family, family.isActive(sessionID) {
        state.run.isRunning = isActive
      }
      if !isActive {
        state.run.isInterrupting = false
        state.run.stopAttempt = nil
      }
    }
    if let shells = snapshot.shells { state.background.shells = shells }
    if let jobs = snapshot.jobs { state.background.jobs = jobs }
    if let inputs = snapshot.pendingInputs { state.pendingInputs = inputs }

    // A page whose session is gone returns to its parent rather than showing a deleted session.
    if let family = state.family {
      let ids = Set(family.sessions.map(\.id))
      while let page = state.pages.last, !ids.contains(page.sessionID) {
        state.pages.removeLast()
      }
    }
  }

  private func mergedFamily(
    _ incoming: Result<SessionFamily, OpenCodeClientError>?,
    rootSession: OpenCodeSession,
    state: State
  ) -> SessionFamily? {
    guard let incoming else { return state.family }
    guard case .success(let family) = incoming else { return state.family }
    guard let previous = state.family, previous.root.id == family.root.id else { return family }
    var ids = Set(family.sessions.map(\.id))
    var sessions = family.sessions
    for old in previous.sessions where ids.insert(old.id).inserted {
      sessions.append(old)
    }
    return SessionFamily(
      root: family.root,
      sessions: sessions,
      activeSessionIDs: family.activeSessionIDs
    )
  }

  // MARK: Events

  private func receive(_ event: ServerEvent, state: inout State) -> Effect<Action> {
    guard owns(event, state: state) else {
      if case .attentionChanged = event {
        return markRacedOrRefresh(event, reason: .invalidation, state: &state)
      }
      return .none
    }
    if var inFlight = state.refresh {
      inFlight.racedEvents.append(event)
      if inFlight.racedEvents.count > 512 {
        inFlight.racedEvents.removeFirst(inFlight.racedEvents.count - 512)
      }
      if inFlight.followup != .runState {
        switch event {
        case .executionStarted, .executionEnded:
          inFlight.followup = .runState
        case .attentionChanged, .inputEnqueued, .inputQueueChanged, .inputCancelled,
          .sessionCreated:
          inFlight.followup = inFlight.followup ?? .invalidation
        case .contentBatch(_, let events):
          if let durable = events.last(where: \.isDurableBoundary) {
            inFlight.followup = inFlight.followup ?? .settlement(messageID: durable.messageID)
          }
        default:
          break
        }
      }
      state.refresh = inFlight
      return .none
    }
    return apply(event, state: &state)
  }

  private func markRacedOrRefresh(
    _ event: ServerEvent,
    reason: RefreshReason,
    state: inout State
  ) -> Effect<Action> {
    if var inFlight = state.refresh {
      inFlight.racedEvents.append(event)
      if inFlight.followup != .runState { inFlight.followup = reason }
      state.refresh = inFlight
      return .none
    }
    return apply(event, state: &state)
  }

  private func apply(raced events: [ServerEvent], state: inout State) {
    for event in events {
      _ = apply(event, recordRaced: true, state: &state)
    }
  }

  @discardableResult
  private func apply(
    _ event: ServerEvent,
    recordRaced: Bool = false,
    state: inout State
  ) -> Effect<Action> {
    switch event {
    case .connected:
      return .none

    case .executionStarted(let id):
      guard owns(id, state: state) else { return .none }
      state.family?.activeSessionIDs.insert(id)
      guard id == state.activeSessionID else { return .none }
      let cancel = supersedeRunWork(&state)
      state.run.isRunning = true
      return .merge(cancel, recordRaced ? .none : .send(.refreshRequested(.runState)))

    case .executionEnded(let id):
      guard owns(id, state: state) else { return .none }
      state.family?.activeSessionIDs.remove(id)
      guard id == state.activeSessionID else { return .none }
      let cancel = supersedeRunWork(&state)
      state.run.isRunning = false
      return .merge(cancel, recordRaced ? .none : .send(.refreshRequested(.runState)))

    case .sessionCreated(let id, let parentID):
      guard let parentID, owns(parentID, state: state) else { return .none }
      return recordRaced ? .none : .send(.refreshRequested(.invalidation))

    case .sessionRenamed(let id, let title):
      updateSession(id, state: &state) { $0.serverTitle = title }
      return .none

    case .sessionMoved(let id, let directory):
      updateSession(id, state: &state) { $0.directory = directory }
      return .none

    case .sessionViewChanged(let id, let idle):
      updateSession(id, state: &state) { $0.viewedMilliseconds = max($0.viewedMilliseconds ?? 0, idle) }
      return .none

    case .sessionDeleted(let id):
      guard owns(id, state: state) else { return .none }
      if state.root?.id == id {
        state.notice = .sessionGone
        state.loadProblem = .notFound
        state.root = nil
        state.family = nil
        state.pages.removeAll()
        return .send(.delegate(.dismiss))
      }
      state.family?.sessions.removeAll { $0.id == id }
      state.pages.removeAll { $0.sessionID == id }
      state.isLoading = true
      return recordRaced ? .none : .send(.refreshRequested(.resume))

    case .sessionArchiveChanged(let id, let isArchived):
      updateSession(id, state: &state) { $0.archivedAt = isArchived ? Date() : nil }
      return .none

    case .inputQueueChanged, .inputEnqueued, .inputCancelled:
      guard owns(event, state: state) else { return .none }
      return .merge(
        recordRaced ? .none : .send(.refreshRequested(.invalidation)),
        fetchPendingInputs(server: state.server, sessionID: state.activeSessionID ?? "")
      )

    case .contentBatch(_, let events):
      guard let durable = events.last(where: \.isDurableBoundary) else { return .none }
      guard !recordRaced else { return .none }
      return .send(.refreshRequested(.settlement(messageID: durable.messageID)))

    case .messageInvalidated(let id):
      guard owns(id, state: state) else { return .none }
      return .none

    case .revertChanged(let id, let messageID, _):
      updateSession(id, state: &state) { $0.revertMessageID = messageID }
      return .none

    case .attentionChanged:
      return recordRaced ? .none : .send(.refreshRequested(.invalidation))

    case .shellStarted(let shell):
      guard shell.sessionID == nil || owns(shell.sessionID!, state: state) else { return .none }
      if let index = state.background.shells.firstIndex(where: { $0.id == shell.id }) {
        state.background.shells[index] = shell
      } else {
        state.background.shells.append(shell)
      }
      return .none

    case .shellEnded(let shellID):
      state.background.shells.removeAll { $0.id == shellID }
      if state.background.output?.shellID == shellID {
        state.background.output?.isUnavailable = true
      }
      return .none

    case .jobUpdated(let job):
      guard owns(job.ownerSessionID, state: state) else { return .none }
      if job.isRunning {
        if let index = state.background.jobs.firstIndex(where: { $0.id == job.id }) {
          state.background.jobs[index] = job
        } else {
          state.background.jobs.append(job)
        }
      } else {
        state.background.jobs.removeAll { $0.id == job.id }
      }
      return .none

    case .projectUpdated, .modelsChanged, .agentsChanged:
      return .none
    }
  }

  private func owns(_ event: ServerEvent, state: State) -> Bool {
    guard let id = event.targetSessionID else {
      if case .attentionChanged = event { return true }
      return true
    }
    return owns(id, state: state)
  }

  private func owns(_ id: String, state: State) -> Bool {
    if state.root?.id == id { return true }
    if state.family?.sessions.contains(where: { $0.id == id }) == true { return true }
    return state.pages.contains { $0.sessionID == id }
  }

  private func updateSession(
    _ id: String,
    state: inout State,
    _ transform: (inout OpenCodeSession) -> Void
  ) {
    if var family = state.family, let index = family.sessions.firstIndex(where: { $0.id == id }) {
      var sessions = family.sessions
      transform(&sessions[index])
      family.sessions = sessions
      if family.root.id == id { family.root = sessions[index] }
      state.family = family
    }
    if var root = state.root, root.id == id {
      transform(&root)
      state.root = root
    }
    if let pageIndex = state.pages.firstIndex(where: { $0.sessionID == id }) {
      state.pages[pageIndex].title = state.family?.session(id)?.title ?? state.pages[pageIndex].title
    }
  }
}

extension RefreshReason {
  /// Metadata, family, requests, shells and jobs. The lighter reasons read only what a run or request
  /// change can affect.
  var readsFamily: Bool {
    switch self {
    case .open, .resume, .reconnect, .watchdog, .snapshot: true
    case .runState, .invalidation, .settlement: false
    }
  }
}

extension SessionFeature {
  // MARK: Family pages

  private func openSubagent(_ sessionID: String, state: inout State) -> Effect<Action> {
    guard let family = state.family, let session = family.session(sessionID),
      sessionID != state.activeSessionID
    else { return .none }
    state.selectionByPage[state.activePage?.id ?? 0] = state.requests.selectedID
    if let index = state.pages.firstIndex(where: { $0.sessionID == sessionID }) {
      state.pages.removeSubrange((index + 1)...)
    } else {
      let page = SessionPage(
        id: state.nextPageID,
        sessionID: session.id,
        title: session.title,
        parentPageID: state.pages.last?.id
      )
      state.nextPageID += 1
      state.pages.append(page)
    }
    state.requests.selectedID = nil
    state.isLoading = true
    let abandon = abandonRefresh(&state)
    return .merge(abandon, requestRefresh(.resume, state: &state))
  }

  private func popPage(state: inout State) -> Effect<Action> {
    guard let leaving = state.pages.popLast() else { return .none }
    state.selectionByPage[leaving.id] = nil
    restoreSelection(pageID: state.activePage?.id ?? 0, state: &state)
    state.isLoading = true
    let abandon = abandonRefresh(&state)
    return .merge(abandon, requestRefresh(.resume, state: &state))
  }

  /// A page change invalidates the read started for the old page rather than letting it finish
  /// against a different active session.
  private func abandonRefresh(_ state: inout State) -> Effect<Action> {
    state.refresh = nil
    return .cancel(id: CancelID.refresh)
  }

  private func restoreSelection(pageID: Int, state: inout State) {
    state.requests.selectedID = state.selectionByPage[pageID] ?? nil
  }

  // MARK: Requests

  private func reconcile(requests: PendingRequests, state: inout State) {
    let incomingIDs = Set(requests.permissions.map(\.id) + requests.forms.map(\.id))
    let completed = state.requests.completedIDs
    let responding = state.requests.respondingIDs

    let keptPermissions = state.requests.permissions.filter {
      responding.contains($0.id) && !incomingIDs.contains($0.id) && !completed.contains($0.id)
    }
    let keptForms = state.requests.forms.filter {
      responding.contains($0.id) && !incomingIDs.contains($0.id) && !completed.contains($0.id)
    }
    state.requests.permissions =
      requests.permissions.filter { !completed.contains($0.id) } + keptPermissions
    state.requests.forms = requests.forms.filter { !completed.contains($0.id) } + keptForms

    var answers: [String: [String: FormValue]] = [:]
    for form in state.requests.forms {
      answers[form.id] = state.requests.answers[form.id] ?? form.defaultAnswers
    }
    state.requests.answers = answers
    state.requests.failures = state.requests.failures.filter { id, _ in
      state.requests.reviewIDs.contains(id) || completed.contains(id)
    }
    state.requests.loadProblem = nil
    if let selected = state.requests.selectedID, !state.requests.reviewIDs.contains(selected) {
      state.requests.selectedID = state.requests.reviewIDs.first
    }
  }

  private func pruneRequest(_ id: String, state: inout State) {
    state.requests.permissions.removeAll { $0.id == id }
    state.requests.forms.removeAll { $0.id == id }
    state.requests.answers[id] = nil
    if state.requests.selectedID == id {
      state.requests.selectedID = state.requests.reviewIDs.first
      state.selectionByPage[state.activePage?.id ?? 0] = state.requests.selectedID
    }
  }

  private func replyPermission(
    id: String,
    decision: PermissionDecision,
    message: String?,
    state: inout State
  ) -> Effect<Action> {
    guard let request = state.requests.permission(id),
      !state.requests.completedIDs.contains(id),
      !state.requests.respondingIDs.contains(id)
    else { return .none }
    if decision == .always, (request.save?.isEmpty ?? true) { return .none }
    let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
    let reason = decision == .reject ? (trimmed?.isEmpty ?? true ? nil : trimmed) : nil
    state.requests.respondingIDs.insert(id)
    state.requests.failures[id] = nil
    haptics.play(.tap)
    let client = client
    let server = state.server
    let sessionID = request.sessionID
    return .run { send in
      do {
        try await client.replyPermission(server, sessionID, id, decision, reason)
        await send(.permissionReplyFinished(requestID: id, sessionID: sessionID, result: .success(true)))
      } catch is CancellationError {
        return
      } catch let error as OpenCodeClientError {
        await send(.permissionReplyFinished(requestID: id, sessionID: sessionID, result: .failure(error)))
      } catch {
        await send(
          .permissionReplyFinished(
            requestID: id,
            sessionID: sessionID,
            result: .failure(OpenCodeClientError(.unreachable))
          )
        )
      }
    }
  }

  private func submitForm(_ id: String, state: inout State) -> Effect<Action> {
    guard let form = state.requests.form(id),
      !state.requests.completedIDs.contains(id),
      !state.requests.respondingIDs.contains(id),
      state.requests.failures[id]?.isSettled != true
    else { return .none }
    let answers = state.requests.answers[id] ?? form.defaultAnswers
    switch form.validatedAnswer(answers: answers) {
    case .failure(let failure):
      haptics.play(.error)
      state.requests.failures[id] = .validation(
        failure.problem,
        fieldKey: failure.fieldKey,
        fieldIndex: failure.fieldIndex
      )
      state.requests.selectedID = id
      return .none
    case .success(let answer):
      state.requests.respondingIDs.insert(id)
      state.requests.failures[id] = nil
      haptics.play(.tap)
      let client = client
      let server = state.server
      let directory = state.activeSession?.directory
      let sessionID = form.sessionID
      return .run { send in
        do {
          let outcome = try await client.replyForm(server, sessionID, id, answer, directory)
          await send(
            .formReplyFinished(
              requestID: id, sessionID: sessionID, dismissal: false, result: .success(outcome)
            )
          )
        } catch is CancellationError {
          return
        } catch let error as OpenCodeClientError {
          await send(
            .formReplyFinished(
              requestID: id, sessionID: sessionID, dismissal: false, result: .failure(error)
            )
          )
        } catch {
          await send(
            .formReplyFinished(
              requestID: id,
              sessionID: sessionID,
              dismissal: false,
              result: .failure(OpenCodeClientError(.unreachable))
            )
          )
        }
      }
    }
  }

  private func cancelForm(_ id: String, state: inout State) -> Effect<Action> {
    guard let form = state.requests.form(id),
      !state.requests.completedIDs.contains(id),
      !state.requests.respondingIDs.contains(id)
    else { return .none }
    if state.requests.failures[id]?.isSettled == true {
      state.requests.completedIDs.insert(id)
      pruneRequest(id, state: &state)
      return .none
    }
    state.requests.respondingIDs.insert(id)
    state.requests.failures[id] = nil
    let client = client
    let server = state.server
    let directory = state.activeSession?.directory
    let sessionID = form.sessionID
    return .run { send in
      do {
        let outcome = try await client.cancelForm(server, sessionID, id, nil, directory)
        await send(
          .formReplyFinished(
            requestID: id, sessionID: sessionID, dismissal: true, result: .success(outcome)
          )
        )
      } catch is CancellationError {
        return
      } catch let error as OpenCodeClientError {
        await send(
          .formReplyFinished(
            requestID: id, sessionID: sessionID, dismissal: true, result: .failure(error)
          )
        )
      } catch {
        await send(
          .formReplyFinished(
            requestID: id,
            sessionID: sessionID,
            dismissal: true,
            result: .failure(OpenCodeClientError(.unreachable))
          )
        )
      }
    }
  }

  // MARK: Run lifecycle

  private func interruptTapped(_ state: inout State) -> Effect<Action> {
    guard state.canInterrupt, let session = state.activeSession else { return .none }
    haptics.play(.cancel)
    let cancelled = supersedeRunWork(&state)
    state.run.isInterrupting = true
    let steering = Set(
      state.pendingInputs
        .filter { $0.delivery == .steer && !$0.isCompaction }
        .map(\.id)
    )
    state.run.stopAttempt = SessionStopAttempt(steering: steering)
    return .merge(
      cancelled,
      interruptEffect(
        server: state.server,
        sessionID: session.id,
        steering: steering,
        generation: state.run.generation
      )
    )
  }

  @discardableResult
  private func supersedeRunWork(_ state: inout State) -> Effect<Action> {
    let previous = state.run.generation
    state.run.generation += 1
    state.run.isInterrupting = false
    state.run.stopAttempt = nil
    return .merge(
      .cancel(id: CancelID.interrupt(previous)),
      .cancel(id: CancelID.interruptSettle(previous)),
      .cancel(id: CancelID.runEndCheck(previous)),
      .cancel(id: CancelID.strandedSteer(previous))
    )
  }

  private enum StopSettlement {
    case ended
    case resumed
    case running
    case unknown
  }

  private func stopSettlement(
    server: OpenCodeServer,
    sessionID: String,
    steering: Set<String>
  ) async -> StopSettlement {
    let active: Bool
    do {
      active = try await client.sessionIsActive(server, sessionID)
    } catch {
      return .unknown
    }
    if !active { return .ended }
    guard !steering.isEmpty else { return .running }
    do {
      let inbox = try await client.pendingInputs(server, sessionID)
      let held = Set(inbox.map(\.id))
      return steering.isSubset(of: held) ? .running : .resumed
    } catch {
      return .unknown
    }
  }

  private func interruptEffect(
    server: OpenCodeServer,
    sessionID: String,
    steering: Set<String>,
    generation: Int
  ) -> Effect<Action> {
    let client = client
    let clock = clock
    let environment = networkPath.retryEnvironment
    return .run { send in
      var schedule = RetrySchedule(policy: .request, clock: clock, environment: environment)
      var failure: OpenCodeClientError?
      var mayHaveLanded = false
      while true {
        if let error = failure {
          mayHaveLanded = mayHaveLanded || error.mayHaveReachedServer
          guard let pause = schedule.next(error.retryVerdict(idempotency: .idempotent)) else {
            break
          }
          do {
            guard try await pause.run() else { break }
          } catch {
            return
          }
          if mayHaveLanded {
            switch await stopSettlement(server: server, sessionID: sessionID, steering: steering) {
            case .ended:
              await send(.runStateRead(sessionID: sessionID, generation: generation, isActive: false))
              return
            case .resumed:
              await send(.interruptResumed(sessionID: sessionID, generation: generation))
              return
            case .unknown:
              continue
            case .running:
              break
            }
          }
        }
        do {
          let interrupted = try await client.interruptSession(server, sessionID)
          AppLog(category: .app).event(
            .sessionInterrupt,
            [LogField("interrupted", .flag(interrupted))]
          )
          await send(
            .interruptAcknowledged(
              sessionID: sessionID, generation: generation, interrupted: interrupted
            )
          )
          return
        } catch is CancellationError {
          return
        } catch let error as OpenCodeClientError {
          failure = error
        } catch {
          failure = OpenCodeClientError(.unreachable)
        }
      }
      await send(.interruptFailed(sessionID: sessionID, generation: generation))
    }
    .cancellable(id: CancelID.interrupt(generation), cancelInFlight: true)
  }

  private func settleStop(readingAtOnce: Bool, state: State) -> Effect<Action> {
    guard let sessionID = state.activeSessionID, let attempt = state.run.stopAttempt else {
      return .none
    }
    let generation = state.run.generation
    let server = state.server
    let clock = clock
    let delays: [Duration] =
      (readingAtOnce ? [.zero] : []) + [
        .seconds(1), .seconds(2), .seconds(4), .seconds(8),
      ]
    return .run { send in
      for delay in delays {
        if delay > .zero {
          do { try await clock.sleep(delay) } catch { return }
        }
        switch await stopSettlement(server: server, sessionID: sessionID, steering: attempt.steering)
        {
        case .ended:
          await send(.runStateRead(sessionID: sessionID, generation: generation, isActive: false))
          return
        case .resumed:
          await send(.interruptResumed(sessionID: sessionID, generation: generation))
          return
        case .running, .unknown:
          continue
        }
      }
      await send(.interruptFailed(sessionID: sessionID, generation: generation))
    }
    .cancellable(id: CancelID.interruptSettle(generation), cancelInFlight: true)
  }

  private func confirmRunState(after delay: Duration, state: State) -> Effect<Action> {
    guard let sessionID = state.activeSessionID else { return .none }
    let generation = state.run.generation
    let server = state.server
    let clock = clock
    let client = client
    return .run { send in
      do { try await clock.sleep(delay) } catch { return }
      let active = (try? await client.sessionIsActive(server, sessionID)) ?? false
      await send(.runStateRead(sessionID: sessionID, generation: generation, isActive: active))
    }
    .cancellable(id: CancelID.runEndCheck(generation), cancelInFlight: true)
  }

  private func strandedSteer(inputID: String, state: inout State) -> Effect<Action> {
    guard !state.run.isRunning,
      let input = state.pendingInputs.first(where: { $0.id == inputID }),
      !input.isCompaction
    else { return .none }
    guard let sessionID = state.activeSessionID else { return .none }
    let fromQueue = input.delivery == .queue
    let cancelled = supersedeRunWork(&state)
    state.run.isRunning = true
    haptics.play(.tap)
    let generation = state.run.generation
    let server = state.server
    let client = client
    let clock = clock
    return .merge(
      cancelled,
      .run { send in
        do {
          if !fromQueue {
            try await client.setPendingInputDelivery(server, sessionID, inputID, .queue)
          }
          try await client.setPendingInputDelivery(server, sessionID, inputID, .steer)
          do { try await clock.sleep(.milliseconds(1_500)) } catch { return }
          let active = (try? await client.sessionIsActive(server, sessionID)) ?? false
          await send(.runStateRead(sessionID: sessionID, generation: generation, isActive: active))
          await send(
            .strandedSteerFinished(
              sessionID: sessionID, generation: generation, inputID: inputID, result: .success(true)
            )
          )
        } catch is CancellationError {
          return
        } catch let error as OpenCodeClientError {
          await send(
            .strandedSteerFinished(
              sessionID: sessionID, generation: generation, inputID: inputID, result: .failure(error)
            )
          )
        } catch {
          await send(
            .strandedSteerFinished(
              sessionID: sessionID,
              generation: generation,
              inputID: inputID,
              result: .failure(OpenCodeClientError(.unreachable))
            )
          )
        }
      }
      .cancellable(id: CancelID.strandedSteer(generation), cancelInFlight: true)
    )
  }

  // MARK: Inbox

  private func fetchPendingInputs(server: OpenCodeServer, sessionID: String) -> Effect<Action> {
    guard !sessionID.isEmpty else { return .none }
    let client = client
    return .run { send in
      do {
        let inputs = try await client.pendingInputs(server, sessionID)
        await send(.pendingInputsLoaded(sessionID: sessionID, result: .success(inputs)))
      } catch is CancellationError {
        return
      } catch let error as OpenCodeClientError {
        await send(.pendingInputsLoaded(sessionID: sessionID, result: .failure(error)))
      } catch {
        await send(
          .pendingInputsLoaded(
            sessionID: sessionID, result: .failure(OpenCodeClientError(.unreachable))
          )
        )
      }
    }
    .cancellable(id: CancelID.pendingInputs, cancelInFlight: true)
  }
}

extension SessionFeature {
  // MARK: Shell output

  private func loadShellTail(shellID: String, state: State) -> Effect<Action> {
    guard let directory = state.activeSession?.directory ?? state.root?.directory else {
      return .none
    }
    let client = client
    let server = state.server
    return .run { send in
      do {
        let probe = try await client.shellOutput(server, directory, shellID, Int.max, 1)
        let start = max(0, probe.size - ShellOutputState.initialTailBytes)
        var output = ""
        var cursor = start
        var pages = 0
        repeat {
          let page = try await client.shellOutput(
            server, directory, shellID, cursor, ShellOutputState.pageBytes
          )
          if page.cursor <= cursor && !output.isEmpty { break }
          output += page.output
          cursor = page.cursor
          pages += 1
        } while cursor < probe.size && pages < 16
        await send(
          .shellOutputPrepared(
            shellID: shellID,
            start: start,
            result: .success(ShellOutputPage(output: output, cursor: cursor, size: probe.size))
          )
        )
      } catch is CancellationError {
        return
      } catch let error as OpenCodeClientError {
        await send(.shellOutputPrepared(shellID: shellID, start: 0, result: .failure(error)))
      } catch {
        await send(
          .shellOutputPrepared(
            shellID: shellID, start: 0, result: .failure(OpenCodeClientError(.unreachable))
          )
        )
      }
    }
    .cancellable(id: CancelID.shellOutput(shellID), cancelInFlight: true)
  }

  private func pollShell(shellID: String, state: State) -> Effect<Action> {
    guard let output = state.background.output, output.shellID == shellID,
      let cursor = output.endCursor, !output.isUnavailable
    else { return .none }
    guard let directory = state.activeSession?.directory ?? state.root?.directory else {
      return .none
    }
    let client = client
    let clock = clock
    let server = state.server
    return .run { send in
      do {
        let shell = try await client.shell(server, directory, shellID)
        if shell.status != .running {
          let page = try await client.shellOutput(
            server, directory, shellID, cursor, ShellOutputState.pageBytes
          )
          await send(.shellOutputLoaded(shellID: shellID, result: .success(page)))
          await send(.shellOutputExited(shellID))
          return
        }
        let page = try await client.shellOutput(
          server, directory, shellID, cursor, ShellOutputState.pageBytes
        )
        await send(.shellOutputLoaded(shellID: shellID, result: .success(page)))
        do { try await clock.sleep(.seconds(1)) } catch { return }
        await send(.shellOutputTick)
      } catch is CancellationError {
        return
      } catch let error as OpenCodeClientError {
        await send(.shellOutputLoaded(shellID: shellID, result: .failure(error)))
        if error.statusCode == 404 { return }
        do { try await clock.sleep(.seconds(3)) } catch { return }
        await send(.shellOutputTick)
      } catch {
        await send(
          .shellOutputLoaded(shellID: shellID, result: .failure(OpenCodeClientError(.unreachable)))
        )
        do { try await clock.sleep(.seconds(3)) } catch { return }
        await send(.shellOutputTick)
      }
    }
    .cancellable(id: CancelID.shellPoll(shellID), cancelInFlight: true)
  }

  private func loadEarlierShellOutput(state: inout State) -> Effect<Action> {
    guard var output = state.background.output, output.canLoadEarlier,
      !output.isLoadingEarlier, !output.isUnavailable,
      let directory = state.activeSession?.directory ?? state.root?.directory
    else { return .none }
    let start = max(0, output.startCursor - ShellOutputState.initialTailBytes)
    let limit = output.startCursor - start
    guard limit > 0 else { return .none }
    output.isLoadingEarlier = true
    state.background.output = output
    let client = client
    let server = state.server
    let shellID = output.shellID
    return .run { send in
      do {
        let page = try await client.shellOutput(server, directory, shellID, start, limit)
        await send(.shellEarlierLoaded(shellID: shellID, start: start, result: .success(page)))
      } catch is CancellationError {
        return
      } catch let error as OpenCodeClientError {
        await send(.shellEarlierLoaded(shellID: shellID, start: start, result: .failure(error)))
      } catch {
        await send(
          .shellEarlierLoaded(
            shellID: shellID, start: start, result: .failure(OpenCodeClientError(.unreachable))
          )
        )
      }
    }
    .cancellable(id: CancelID.shellEarlier(shellID), cancelInFlight: true)
  }

  private func stopShell(state: inout State) -> Effect<Action> {
    guard var output = state.background.output, !output.isUnavailable, output.isStopping,
      let directory = state.activeSession?.directory ?? state.root?.directory
    else { return .none }
    let client = client
    let server = state.server
    let shellID = output.shellID
    let cursor = output.endCursor
    output.isStopping = true
    state.background.output = output
    return .run { send in
      // Stopping discards the server's capture, so read what is left before the delete.
      if let cursor {
        if let page = try? await client.shellOutput(
          server, directory, shellID, cursor, ShellOutputState.pageBytes
        ) {
          await send(.shellOutputLoaded(shellID: shellID, result: .success(page)))
        }
      }
      do {
        try await client.stopShell(server, directory, shellID)
        await send(.shellStopFinished(shellID: shellID, error: nil))
      } catch is CancellationError {
        return
      } catch let error as OpenCodeClientError {
        await send(.shellStopFinished(shellID: shellID, error: error))
      } catch {
        await send(.shellStopFinished(shellID: shellID, error: OpenCodeClientError(.unreachable)))
      }
    }
    .cancellable(id: CancelID.shellStop(shellID), cancelInFlight: true)
  }

  private func trimShellOutput(_ text: String, limit: Int) -> String {
    let bytes = Array(text.utf8)
    guard bytes.count > limit else { return text }
    var cut = bytes.count - limit
    let searchEnd = min(cut + 4_096, bytes.count)
    if let newline = bytes[cut..<searchEnd].firstIndex(of: 0x0A) {
      cut = newline + 1
    } else {
      while cut < bytes.count, bytes[cut] & 0xC0 == 0x80 { cut += 1 }
    }
    return String(decoding: bytes[cut...], as: UTF8.self)
  }

  // MARK: Notices

  private func noticeExpiry() -> Effect<Action> {
    let clock = clock
    return .run { send in
      do { try await clock.sleep(.seconds(4)) } catch { return }
      await send(.noticeDismissed)
    }
    .cancellable(id: CancelID.notice, cancelInFlight: true)
  }
}

// MARK: - Helpers

private func capture<T>(_ operation: @Sendable () async throws -> T) async
  -> Result<T, OpenCodeClientError>
{
  do {
    return .success(try await operation())
  } catch is CancellationError {
    return .failure(OpenCodeClientError(.unreachable))
  } catch let error as OpenCodeClientError {
    return .failure(error)
  } catch {
    return .failure(OpenCodeClientError(.unreachable))
  }
}
