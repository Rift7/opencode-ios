import ComposableArchitecture
import Foundation
import OpenCodeComposer
import OpenCodeCore
import OpenCodeServer
import OpenCodeTranscript

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
    public var transcripts: [String: TranscriptState]
    public var pendingLink: URL?
    public var inspectedFile: TranscriptFile?
    public var composer: ComposerFeature.State
    public var requestDock: RequestDockState

    public var refresh: SessionRefresh?
    /// Set when a raced-event overflow made the projection incomplete. Survives failed reads.
    public var recovery: SessionRecovery?
    var nextRefreshID: Int
    var nextPageID: Int
    var selectionByPage: [Int: String?]
    var didStart: Bool
    var composerSend: ComposerSendOperation?
    var nextComposerOperation: Int

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
      self.transcripts = [:]
      self.pendingLink = nil
      self.inspectedFile = nil
      self.requestDock = RequestDockState()
      self.refresh = nil
      self.recovery = nil
      self.nextRefreshID = 0
      self.nextPageID = 1
      self.selectionByPage = [0: nil]
      self.didStart = false
      self.composerSend = nil
      self.nextComposerOperation = 0

      let target: ComposerTarget
      if session == nil, case .newSession(let directory) = selection.intent {
        target = .newSession(id: selection.sessionID, directory: directory)
      } else {
        target = .session(id: session?.id ?? selection.sessionID)
      }
      self.composer = ComposerFeature.State(serverID: server.persistenceID, target: target)
      if session == nil, case .newSession = selection.intent {
        self.isLoading = false
      }
    }

    /// A new-session composer before its first send created the session.
    public var isNewSessionDraft: Bool {
      root == nil && composer.target.isNewSession
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
        && lhs.transcripts == rhs.transcripts
        && lhs.pendingLink == rhs.pendingLink
        && lhs.inspectedFile == rhs.inspectedFile
        && lhs.recovery == rhs.recovery
        && lhs.composer == rhs.composer
        && lhs.requestDock == rhs.requestDock
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

    public var activeTranscript: TranscriptState? {
      activeSessionID.flatMap { transcripts[$0] }
    }

    public func transcript(for sessionID: String) -> TranscriptState? {
      transcripts[sessionID]
    }

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

    case composer(ComposerFeature.Action)
    case flushForDismiss(UUID)
    case composerSendResult(
      operationID: Int,
      messageID: String,
      result: ComposerSendResult
    )
    case composerWaitFinished(operationID: Int, sessionID: String, messageID: String)
    case composerSessionLoaded(sessionID: String, result: Result<OpenCodeSession, OpenCodeClientError>)

    case pendingInputSendNowTapped(String)
    case pendingInputQueueTapped(String)
    case pendingInputCancelTapped(String)
    case pendingInputDeliveryFinished(
      sessionID: String,
      inputID: String,
      previous: PendingInput.Delivery?,
      result: Result<Bool, OpenCodeClientError>
    )
    case pendingInputCancelFinished(
      sessionID: String,
      inputID: String,
      result: Result<Bool, OpenCodeClientError>
    )

    case requestAnswerChanged(String)
    case requestPageChanged(Int)
    case requestDockToggled(String)
    case requestReviewTapped
    case requestSheetDismissed
    case requestBarSendTapped

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
    case shellDrainPage(shellID: String, page: ShellOutputPage)
    case shellDrainFailed(shellID: String, error: OpenCodeClientError)
    case shellDiscardUnreadConfirmed
    case shellDiscardCancelled
    case shellStopFinished(shellID: String, error: OpenCodeClientError?)
    case jobCancelTapped(jobID: String)
    case jobCancelFinished(jobID: String, error: OpenCodeClientError?)
    case backgroundProblemDismissed

    case recoveryRetry
    case transcriptEarlierTapped
    case transcriptEarlierFinished(
      sessionID: String,
      generation: Int,
      cursor: String?,
      result: Result<TranscriptPage, OpenCodeClientError>
    )
    case transcriptDisclosureToggled(String)
    case transcriptFollowChanged(sessionID: String, isFollowing: Bool, anchorID: String?)
    case transcriptJumpTapped
    case transcriptCopyTapped(String)
    case transcriptQuoteTapped(String)
    case transcriptLinkTapped(String)
    case transcriptLinkConfirmed
    case transcriptLinkCopyTapped
    case transcriptLinkCancelled
    case transcriptFileTapped(TranscriptFile)
    case transcriptFileDismissed
    case transcriptFileCopyTapped

    case noticeDismissed
    case delegate(Delegate)
  }

  public enum Delegate: Equatable, Sendable {
    case dismiss
    case dismissReady(
      requestID: UUID,
      serverID: String,
      sessionID: String,
      result: ComposerDraftSave
    )
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
    case recoveryRetry
    case transcriptEarlier
    case notice
    case composerSend(Int)
    case composerWait(Int)
    case pendingInput(String)
  }

  @Dependency(\.openCodeClient) private var client
  @Dependency(\.clock) private var clock
  @Dependency(\.networkPath) private var networkPath
  @Dependency(\.haptics) private var haptics
  @Dependency(\.pasteboard) private var pasteboard
  @Dependency(\.linkOpener) private var linkOpener
  @Dependency(\.uuidClient) private var uuid

  public init() {}

  public var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        guard !state.didStart else { return .none }
        state.didStart = true
        guard !state.isPinned else { return .none }
        if state.isNewSessionDraft {
          return .merge(
            .send(.composer(.task)),
            .send(.composer(.focusRequested))
          )
        }
        return .merge(
          requestRefresh(.open, state: &state),
          .send(.composer(.task))
        )

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

      case .recoveryRetry:
        guard state.recovery?.sessionID == state.activeSessionID else { return .none }
        return requestRefresh(.recovery(messageID: state.recovery?.settlementMessageID), state: &state)

      case .connectionChanged(let isConnected):
        let wasLive = state.isLive
        state.isLive = isConnected
        if isConnected {
          guard !wasLive else { return .none }
          var effects: [Effect<Action>] = [requestRefresh(.reconnect, state: &state)]
          if let output = state.background.output, output.isVisible, output.isLoaded,
            !output.isUnavailable, !output.isStopping, !output.requiresDiscardConfirmation
          {
            effects.append(pollShell(shellID: output.shellID, state: state))
          }
          return .merge(effects)
        }
        state.refresh = nil
        state.nextRefreshID += 1
        if var output = state.background.output {
          output.isStopping = false
          state.background.output = output
        }
        let shellID = state.background.output?.shellID
        var effects: [Effect<Action>] = [
          .cancel(id: CancelID.refresh),
          .cancel(id: CancelID.requests),
          .cancel(id: CancelID.pendingInputs),
          .cancel(id: CancelID.interruptSettle(state.run.generation)),
          .cancel(id: CancelID.runEndCheck(state.run.generation)),
          .cancel(id: CancelID.transcriptEarlier),
          .cancel(id: CancelID.recoveryRetry),
        ]
        if let sessionID = state.activeSessionID, var transcript = state.transcripts[sessionID],
          case .loading(let cursor, let reached) = transcript.earlier
        {
          transcript.earlier = reached ? .paging(cursor: cursor) : .seekingOverlap(cursor: cursor)
          state.transcripts[sessionID] = transcript
        }
        if let shellID {
          effects += [
            .cancel(id: CancelID.shellPoll(shellID)),
            .cancel(id: CancelID.shellOutput(shellID)),
            .cancel(id: CancelID.shellEarlier(shellID)),
            .cancel(id: CancelID.shellStop(shellID)),
          ]
        }
        return .merge(effects)

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

      case .composer(let action):
        guard case .delegate(let delegate) = action else { return .none }
        switch delegate {
        case .send(let send):
          return startComposerSend(send, isRetry: false, state: &state)
        case .retry(let failed):
          return startComposerSend(failed.send, isRetry: true, state: &state)
        case .restoredCreatedSession(let sessionID):
          return adoptRestoredSession(sessionID, state: &state)
        case .flushForDismissFinished(let requestID, let result):
          return .send(
            .delegate(
              .dismissReady(
                requestID: requestID,
                serverID: state.server.persistenceID,
                sessionID: state.selection.sessionID,
                result: result
              )
            )
          )
        }

      case .flushForDismiss(let requestID):
        return .send(.composer(.flushForDismiss(requestID)))

      case .composerSendResult(let operationID, let messageID, let result):
        return composerSendResult(
          operationID: operationID,
          messageID: messageID,
          result: result,
          state: &state
        )

      case .composerWaitFinished(let operationID, let sessionID, let messageID):
        guard state.composerSend == nil,
          state.activeSessionID == sessionID || state.selection.sessionID == sessionID
        else { return .none }
        AppLog(category: .send).event(
          .composerWaitFinished,
          [LogField("operation", .count(operationID)), LogField("session", .flag(true))]
        )
        return .send(.refreshRequested(.settlement(messageID: messageID)))

      case .composerSessionLoaded(let sessionID, let result):
        guard state.composer.target.sessionID == sessionID
          || state.selection.sessionID == sessionID
        else { return .none }
        switch result {
        case .success(let session):
          adopt(session, state: &state)
          return .merge(
            .send(.composer(.sessionCreated(session.id))),
            requestRefresh(.open, state: &state)
          )
        case .failure:
          return .send(.composer(.sendBlocked(.couldNotRestore)))
        }

      case .pendingInputSendNowTapped(let inputID):
        return pendingInputSendNow(inputID, state: &state)

      case .pendingInputQueueTapped(let inputID):
        return pendingInputQueue(inputID, state: &state)

      case .pendingInputCancelTapped(let inputID):
        return pendingInputCancel(inputID, state: &state)

      case .pendingInputDeliveryFinished(let sessionID, let inputID, let previous, let result):
        guard sessionID == state.activeSessionID else { return .none }
        switch result {
        case .success:
          return fetchPendingInputs(server: state.server, sessionID: sessionID)
        case .failure:
          if let previous, let index = state.pendingInputs.firstIndex(where: { $0.id == inputID }) {
            state.pendingInputs[index].delivery = previous
          }
          haptics.play(.error)
          state.notice = .couldNotUpdateInput
          return .merge(
            fetchPendingInputs(server: state.server, sessionID: sessionID),
            noticeExpiry()
          )
        }

      case .pendingInputCancelFinished(let sessionID, let inputID, let result):
        guard sessionID == state.activeSessionID else { return .none }
        switch result {
        case .success:
          state.pendingInputs.removeAll { $0.id == inputID }
          return fetchPendingInputs(server: state.server, sessionID: sessionID)
        case .failure:
          haptics.play(.error)
          state.notice = .couldNotCancelInput
          return .merge(
            fetchPendingInputs(server: state.server, sessionID: sessionID),
            noticeExpiry()
          )
        }

      case .requestAnswerChanged(let text):
        guard state.requests.hasPending else { return .none }
        var dock = state.requestDock
        let requests = state.requests
        dock.answerChanged(text, request: requests, answers: &state.requests.answers)
        state.requestDock = dock
        if let id = state.requests.selectedRequestID,
          case .validation = state.requests.failures[id]
        {
          state.requests.failures[id] = nil
        }
        return .none

      case .requestPageChanged(let delta):
        guard let id = state.requests.selectedRequestID,
          let form = state.requests.form(id),
          !state.requests.respondingIDs.contains(id)
        else { return .none }
        let answers = state.requests.answers[id] ?? form.defaultAnswers
        _ = state.requestDock.movePage(delta, form: form, answers: answers)
        return .none

      case .requestDockToggled(let id):
        if state.requestDock.collapsedIDs.contains(id) {
          state.requestDock.collapsedIDs.remove(id)
        } else {
          state.requestDock.collapsedIDs.insert(id)
        }
        return .none

      case .requestReviewTapped:
        guard state.requests.hasPending else { return .none }
        state.requestDock.showsSheet = true
        return .none

      case .requestSheetDismissed:
        state.requestDock.showsSheet = false
        return .none

      case .requestBarSendTapped:
        return sendRequestBar(state: &state)

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
        return .merge(
          abandon,
          requestRefresh(.resume, state: &state),
          .send(.composer(.switchTarget(.session(id: state.root?.id ?? state.selection.sessionID))))
        )

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
        guard var output = state.background.output, !output.isUnavailable else { return .none }
        output.isVisible = true
        state.background.output = output
        guard output.isLoaded else { return .none }
        return pollShell(shellID: output.shellID, state: state)

      case .shellOutputDisappeared:
        guard var output = state.background.output else { return .none }
        output.isVisible = false
        state.background.output = output
        return .cancel(id: CancelID.shellPoll(output.shellID))

      case .shellOutputTick:
        guard let output = state.background.output, output.isVisible,
          !output.isUnavailable, !output.isStopping, !output.requiresDiscardConfirmation
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
        if output.isVisible, output.isLoaded, !output.isUnavailable {
          return pollShell(shellID: shellID, state: state)
        }
        return .none

      case .shellOutputLoaded(let shellID, let result):
        guard var output = state.background.output, output.shellID == shellID,
          !output.isStopping
        else { return .none }
        switch result {
        case .success(let page):
          guard let end = output.endCursor, page.cursor > end else { return .none }
          let trimmed = trimShellOutput(output.output + page.output, limit: output.retainLimit)
          output.output = trimmed.text
          output.startCursor += trimmed.discardedBytes
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
          let capacity = ShellOutputState.maximumRetainedBytes - output.output.utf8.count
          guard capacity > 0 else {
            state.background.output = output
            return .none
          }
          var bytes = Array(page.output.utf8)
          if bytes.count > capacity {
            // Keep the suffix nearest the retained range, then align to a UTF-8 lead byte.
            var cut = bytes.count - capacity
            while cut < bytes.count, bytes[cut] & 0xC0 == 0x80 { cut += 1 }
            bytes = Array(bytes[cut...])
          }
          let added = String(decoding: bytes, as: UTF8.self)
          output.output = added + output.output
          output.startCursor = page.cursor - bytes.count
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
        output.requiresDiscardConfirmation = false
        state.background.output = output
        return .none

      case .shellStopConfirmed:
        guard let shellID = state.background.output?.shellID else { return .none }
        return .merge(
          .cancel(id: CancelID.shellPoll(shellID)),
          stopShell(state: &state)
        )

      case .shellDrainPage(let shellID, let page):
        guard var output = state.background.output, output.shellID == shellID,
          let end = output.endCursor, page.cursor > end
        else { return .none }
        let trimmed = trimShellOutput(output.output + page.output, limit: output.retainLimit)
        output.output = trimmed.text
        output.startCursor += trimmed.discardedBytes
        output.endCursor = page.cursor
        output.size = page.size
        state.background.output = output
        return .none

      case .shellDrainFailed(let shellID, let error):
        guard var output = state.background.output, output.shellID == shellID else {
          return .none
        }
        output.isStopping = false
        output.requiresDiscardConfirmation = true
        output.problem = .from(error, isOffline: !state.isLive)
        state.background.output = output
        haptics.play(.error)
        return .none

      case .shellDiscardUnreadConfirmed:
        guard var output = state.background.output,
          output.requiresDiscardConfirmation, !output.isUnavailable
        else { return .none }
        output.requiresDiscardConfirmation = false
        output.isStopping = true
        state.background.output = output
        return discardUnreadAndStopShell(state: &state)

      case .shellDiscardCancelled:
        guard var output = state.background.output else { return .none }
        output.requiresDiscardConfirmation = false
        output.isStopping = false
        output.problem = nil
        state.background.output = output
        return output.isVisible ? pollShell(shellID: output.shellID, state: state) : .none

      case .shellStopFinished(let shellID, let error):
        guard var output = state.background.output, output.shellID == shellID else { return .none }
        output.isStopping = false
        output.requiresDiscardConfirmation = false
        if let error, error.statusCode != 404 {
          haptics.play(.error)
          output.problem = .from(error, isOffline: !state.isLive)
          state.background.output = output
          return output.isVisible ? pollShell(shellID: shellID, state: state) : .none
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

      case .transcriptEarlierTapped:
        return loadEarlierTranscript(state: &state)

      case .transcriptEarlierFinished(let sessionID, let generation, let cursor, let result):
        return earlierTranscriptFinished(
          sessionID: sessionID,
          generation: generation,
          cursor: cursor,
          result: result,
          state: &state
        )

      case .transcriptDisclosureToggled(let entryID):
        guard let sessionID = state.activeSessionID,
          var transcript = state.transcripts[sessionID]
        else { return .none }
        if transcript.expandedIDs.contains(entryID) {
          transcript.expandedIDs.remove(entryID)
        } else {
          transcript.expandedIDs.insert(entryID)
        }
        state.transcripts[sessionID] = transcript
        return .none

      case .transcriptFollowChanged(let sessionID, let isFollowing, let anchorID):
        guard var transcript = state.transcripts[sessionID] else { return .none }
        guard transcript.isFollowing != isFollowing || transcript.scrollAnchorID != anchorID else {
          return .none
        }
        transcript.isFollowing = isFollowing
        transcript.showsJumpToLatest = !isFollowing
        if let anchorID { transcript.scrollAnchorID = anchorID }
        state.transcripts[sessionID] = transcript
        return .none

      case .transcriptJumpTapped:
        guard let sessionID = state.activeSessionID, var transcript = state.transcripts[sessionID]
        else { return .none }
        transcript.isFollowing = true
        transcript.showsJumpToLatest = false
        state.transcripts[sessionID] = transcript
        return .none

      case .transcriptCopyTapped(let text):
        guard !text.isEmpty else { return .none }
        pasteboard.setString(text)
        haptics.play(.confirm)
        AppLog(category: .app).event(
          .transcriptCopied,
          [LogField("characters", .count(text.count))]
        )
        return .none

      case .transcriptQuoteTapped(let text):
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
        return .send(.composer(.quoteInserted(text: text)))

      case .transcriptLinkTapped(let text):
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
          ["http", "https", "mailto"].contains(scheme)
        else { return .none }
        state.pendingLink = url
        return .none

      case .transcriptLinkConfirmed:
        guard let url = state.pendingLink else { return .none }
        state.pendingLink = nil
        let open = linkOpener.open
        return .run { _ in _ = await open(url) }

      case .transcriptLinkCopyTapped:
        guard let url = state.pendingLink else { return .none }
        pasteboard.setString(url.absoluteString)
        state.pendingLink = nil
        haptics.play(.confirm)
        return .none

      case .transcriptLinkCancelled:
        state.pendingLink = nil
        return .none

      case .transcriptFileTapped(let file):
        state.inspectedFile = file
        return .none

      case .transcriptFileDismissed:
        state.inspectedFile = nil
        return .none

      case .transcriptFileCopyTapped:
        guard let path = state.inspectedFile?.path, !path.isEmpty else { return .none }
        pasteboard.setString(path)
        haptics.play(.confirm)
        return .none

      case .noticeDismissed:
        state.notice = nil
        return .none

      case .delegate:
        return .none
      }
    }
    Scope(state: \.composer, action: \.composer) {
      ComposerFeature()
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
  public var transcript: Result<TranscriptPage, OpenCodeClientError>?

  public init(
    session: OpenCodeSession,
    family: Result<SessionFamily, OpenCodeClientError>? = nil,
    requests: Result<PendingRequests, OpenCodeClientError>? = nil,
    isActive: Bool? = nil,
    shells: [ServerShell]? = nil,
    jobs: [ServerJob]? = nil,
    pendingInputs: [PendingInput]? = nil,
    transcript: Result<TranscriptPage, OpenCodeClientError>? = nil
  ) {
    self.session = session
    self.family = family
    self.requests = requests
    self.isActive = isActive
    self.shells = shells
    self.jobs = jobs
    self.pendingInputs = pendingInputs
    self.transcript = transcript
  }
}

extension SessionFeature {
  // MARK: Refresh

  private func requestRefresh(_ requestedReason: RefreshReason, state: inout State) -> Effect<Action> {
    guard state.isLive, !state.isPinned else { return .none }
    guard let sessionID = state.activeSessionID ?? Optional(state.selection.sessionID) else {
      return .none
    }
    if var recovery = state.recovery, recovery.sessionID == sessionID,
      let messageID = requestedReason.messageID
    {
      recovery.settlementMessageID = messageID
      state.recovery = recovery
    }
    let reason: RefreshReason = state.recovery?.sessionID == sessionID
      ? .recovery(messageID: state.recovery?.settlementMessageID)
      : requestedReason

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
    if state.transcripts[sessionID] == nil {
      state.transcripts[sessionID] = TranscriptState(sessionID: sessionID)
    }
    if case .recovery = reason, var recovery = state.recovery {
      recovery.attempts += 1
      state.recovery = recovery
    }
    state.refresh = SessionRefresh(id: requestID, reason: reason)
    if state.root == nil { state.isLoading = true }
    let familyRoot = state.family?.root
      ?? (state.root?.id == state.selection.sessionID ? state.root : nil)
    return refreshEffect(
      server: state.server,
      sessionID: sessionID,
      requestID: requestID,
      reason: reason,
      familyRoot: familyRoot,
      familyRootID: state.family?.root.id ?? state.selection.sessionID,
      knownFamily: state.family?.sessions.map(\.id) ?? []
    )
  }

  private func refreshEffect(
    server: OpenCodeServer,
    sessionID: String,
    requestID: Int,
    reason: RefreshReason,
    familyRoot: OpenCodeSession?,
    familyRootID: String,
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
        // The family is always discovered from its root, even while a subagent page is active.
        // The live walk returns the subtree of whatever root it is given.
        let familyReadRoot: OpenCodeSession? = familyRoot
          ?? (session.id == familyRootID ? session : nil)
        if let familyReadRoot {
          family = await capture {
            try await client.sessionFamily(server, familyReadRoot)
          }
        }
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
      async let transcript: Result<TranscriptPage, OpenCodeClientError>? = capture {
        try await client.transcript(server, sessionID, TranscriptState.initialLimit)
      }

      let snapshot = SessionSnapshot(
        session: session,
        family: family,
        requests: await requests,
        isActive: try? await active.get(),
        shells: try? await shells?.get(),
        jobs: try? await jobs?.get(),
        pendingInputs: try? await inputs?.get(),
        transcript: await transcript
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
    let isInitialSelection = state.root == nil
      && state.family == nil
      && state.selection.sessionID == sessionID
    guard state.activeSessionID == sessionID
      || state.root?.id == sessionID
      || isInitialSelection
    else {
      state.refresh = nil
      return .none
    }
    let wasRecovery: Bool
    if case .recovery = inFlight.reason { wasRecovery = true } else { wasRecovery = false }

    switch result {
    case .failure(let error):
      state.refresh = nil
      state.isLoading = false
      AppLog(category: .app).event(
        .sessionRefreshFailed,
        [LogField("status", .status(error.statusCode ?? 0))]
      )
      if !inFlight.racedEventsIncomplete {
        apply(raced: inFlight.racedEvents, state: &state)
      }
      applyTranscriptFailure(
        .from(error, isOffline: !state.isLive),
        for: sessionID,
        state: &state
      )
      if state.root == nil {
        state.loadProblem = .from(error, isOffline: !state.isLive)
      } else {
        state.notice = .couldNotRefresh(.from(error, isOffline: !state.isLive))
      }
      if inFlight.racedEventsIncomplete {
        mergeRecovery(from: inFlight, for: sessionID, state: &state)
      }
      guard state.recovery?.sessionID == sessionID else { return .none }
      AppLog(category: .app).event(
        .sessionRefreshIncomplete,
        [LogField("rehydrate", .flag(true))]
      )
      return scheduleRecovery(for: sessionID, wasRecovery: wasRecovery, state: &state)

    case .success(let snapshot):
      state.refresh = nil
      state.isLoading = false
      state.loadProblem = nil
      state.notice = nil
      apply(snapshot: snapshot, for: sessionID, state: &state)
      let transcriptFailed: Bool
      if case .failure = snapshot.transcript { transcriptFailed = true } else { transcriptFailed = false }

      if inFlight.racedEventsIncomplete {
        mergeRecovery(from: inFlight, for: sessionID, state: &state)
        AppLog(category: .app).event(
          .sessionRefreshIncomplete,
          [LogField("rehydrate", .flag(true))]
        )
        return scheduleRecovery(for: sessionID, wasRecovery: wasRecovery, state: &state)
      }

      if wasRecovery, transcriptFailed {
        // The recovery attempt started but the transcript did not read: keep the requirement.
        AppLog(category: .app).event(
          .sessionRefreshIncomplete,
          [LogField("rehydrate", .flag(true))]
        )
        return scheduleRecovery(for: sessionID, wasRecovery: true, state: &state)
      }

      apply(raced: inFlight.racedEvents, state: &state)
      var effects: [Effect<Action>] = []
      if wasRecovery {
        let attempts = state.recovery?.attempts ?? 0
        state.recovery = nil
        effects.append(.cancel(id: CancelID.recoveryRetry))
        AppLog(category: .app).event(
          .sessionRecovered,
          [LogField("attempts", .count(attempts))]
        )
      }
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
      if let followup {
        effects.append(.send(.refreshRequested(followup)))
      }
      return effects.isEmpty ? .none : .merge(effects)
    }
  }

  private func mergeRecovery(
    from inFlight: SessionRefresh,
    for sessionID: String,
    state: inout State
  ) {
    var recovery: SessionRecovery
    if let existing = state.recovery, existing.sessionID == sessionID {
      recovery = existing
    } else {
      recovery = SessionRecovery(sessionID: sessionID)
    }
    if let settled = inFlight.recoverySettlementMessageID ?? inFlight.followup?.messageID {
      recovery.settlementMessageID = settled
    }
    state.recovery = recovery
  }

  /// One immediate recovery after the overflowing read, then at most one delayed automatic retry.
  /// A failed recovery leaves `state.recovery` set so a manual retry or reconnect can try again.
  private func scheduleRecovery(
    for sessionID: String,
    wasRecovery: Bool,
    state: inout State
  ) -> Effect<Action> {
    guard let recovery = state.recovery, recovery.sessionID == sessionID else { return .none }
    if !wasRecovery {
      return .send(.refreshRequested(.recovery(messageID: recovery.settlementMessageID)))
    }
    guard recovery.canRetryAutomatically else {
      if state.notice == nil { state.notice = .couldNotRefresh(.unknown) }
      return .none
    }
    let clock = clock
    return .run { send in
      do { try await clock.sleep(.seconds(1)) } catch { return }
      await send(.recoveryRetry)
    }
    .cancellable(id: CancelID.recoveryRetry, cancelInFlight: true)
  }

  private func apply(snapshot: SessionSnapshot, for sessionID: String, state: inout State) {
    if state.root == nil || state.root?.id == sessionID || sessionID == state.selection.sessionID {
      state.root = snapshot.session
    }
    if let incoming = snapshot.family, case .success(let family) = incoming {
      if let previous = state.family, previous.root.id != family.root.id {
        // A narrower subtree must not replace the family the screen is navigating.
      } else {
        state.family = mergedFamily(family, previous: state.family)
      }
    }
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
      if state.activeSessionID == sessionID {
        state.run.isRunning = isActive
        if !isActive {
          state.run.isInterrupting = false
          state.run.stopAttempt = nil
        }
      }
      if isActive {
        state.family?.activeSessionIDs.insert(sessionID)
      } else {
        state.family?.activeSessionIDs.remove(sessionID)
      }
    }
    if let shells = snapshot.shells { state.background.shells = shells }
    if let jobs = snapshot.jobs { state.background.jobs = jobs }
    if let inputs = snapshot.pendingInputs { state.pendingInputs = inputs }
    if let transcript = snapshot.transcript {
      switch transcript {
      case .success(let page):
        applyTranscript(page, for: sessionID, state: &state)
      case .failure(let error):
        applyTranscriptFailure(.from(error, isOffline: !state.isLive), for: sessionID, state: &state)
      }
    }

    // A page whose session is gone returns to its parent rather than showing a deleted session.
    if let family = state.family {
      let ids = Set(family.sessions.map(\.id))
      while let page = state.pages.last, !ids.contains(page.sessionID) {
        state.pages.removeLast()
      }
    }
  }

  private func mergedFamily(
    _ family: SessionFamily,
    previous: SessionFamily?
  ) -> SessionFamily {
    guard let previous, previous.root.id == family.root.id else { return family }
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
      recordRaced(event, in: &inFlight)
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
      recordRaced(event, in: &inFlight)
      if inFlight.followup != .runState { inFlight.followup = reason }
      state.refresh = inFlight
      return .none
    }
    return apply(event, state: &state)
  }

  /// Bounded replay for events that race one authoritative read. The buffer is a safety bound,
  /// not a lossy queue: crossing it marks the projection incomplete, discards the partial replay
  /// and makes the refresh coordinator take another authoritative read after this one.
  private func recordRaced(_ event: ServerEvent, in inFlight: inout SessionRefresh) {
    if !inFlight.racedEventsIncomplete {
      if inFlight.racedEvents.count >= 512 {
        inFlight.racedEventsIncomplete = true
        inFlight.racedEvents.removeAll(keepingCapacity: false)
        if inFlight.recoverySettlementMessageID == nil {
          inFlight.recoverySettlementMessageID = inFlight.followup?.messageID
        }
      } else {
        inFlight.racedEvents.append(event)
      }
    }
    guard inFlight.followup != .runState else { return }
    switch event {
    case .executionStarted, .executionEnded:
      inFlight.followup = .runState
    case .messageInvalidated:
      inFlight.followup = inFlight.followup ?? .invalidation
    case .attentionChanged, .inputEnqueued, .inputQueueChanged, .inputCancelled,
      .sessionCreated:
      inFlight.followup = inFlight.followup ?? .invalidation
    case .contentBatch(_, let events):
      if let durable = events.last(where: \.isDurableBoundary) {
        if inFlight.racedEventsIncomplete {
          inFlight.recoverySettlementMessageID = durable.messageID
        }
        inFlight.followup = inFlight.followup ?? .settlement(messageID: durable.messageID)
      }
    default:
      break
    }
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
      state.transcripts[id] = nil
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

    case .contentBatch(let sessionID, let events):
      applyLiveTranscript(events, for: sessionID, state: &state)
      guard !recordRaced else { return .none }
      guard let durable = events.last(where: \.isDurableBoundary) else { return .none }
      return .send(.refreshRequested(.settlement(messageID: durable.messageID)))

    case .messageInvalidated(let id):
      guard owns(id, state: state) else { return .none }
      return recordRaced ? .none : .send(.refreshRequested(.invalidation))

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

extension SessionFeature {
  // MARK: Composer

  private func startComposerSend(
    _ send: ComposerSend,
    isRetry: Bool,
    state: inout State
  ) -> Effect<Action> {
    guard send.hasContent else { return .send(.composer(.sendBlocked(.couldNotSend))) }
    guard state.composerSend == nil else { return .send(.composer(.sendBlocked(.busy))) }
    guard !state.requests.hasPending else {
      return .send(.composer(.sendBlocked(.requestPending)))
    }
    guard state.isLive else {
      return .send(.composer(.sendBlocked(.notConnected)))
    }
    let target = send.target
    let directory = target.directory
    let existingSessionID = target.sessionID
    let newSessionID = target.newSessionID
    guard existingSessionID != nil || (directory != nil && newSessionID != nil) else {
      return .send(.composer(.sendBlocked(.couldNotSend)))
    }
    state.nextComposerOperation += 1
    let operationID = state.nextComposerOperation
    state.composerSend = ComposerSendOperation(
      id: operationID,
      send: send,
      isRetry: isRetry,
      createdSession: nil
    )
    if let existingSessionID {
      showOptimistic(send, messageID: send.messageID, sessionID: existingSessionID, state: &state)
    }

    let client = client
    let server = state.server
    AppLog(category: .send).event(
      .composerSent,
      [
        LogField("retry", .flag(isRetry)),
        LogField("newSession", .flag(existingSessionID == nil)),
        LogField("characters", .count(send.text.count)),
        LogField("quotes", .count(send.quotes.count)),
      ]
    )
    return .run { emit in
      let actual = send
      var created: OpenCodeSession?
      var sessionID = existingSessionID
      var reconciledRetry = !isRetry

      if isRetry, let sessionID {
        let found = await reconcileMessage(
          messageID: actual.messageID,
          sessionID: sessionID,
          server: server,
          client: client
        )
        switch found {
        case .found:
          await emit(
            .composerSendResult(
              operationID: operationID,
              messageID: actual.messageID,
              result: .accepted(sessionID: sessionID, created: nil)
            )
          )
          return
        case .unreadable:
          await emit(
            .composerSendResult(
              operationID: operationID,
              messageID: actual.messageID,
              result: .unverified(created: nil)
            )
          )
          return
        case .absent:
          await emit(
            .composerSendResult(
              operationID: operationID,
              messageID: actual.messageID,
              result: .retryAbsent(created: nil)
            )
          )
          return
        }
      }

      if sessionID == nil {
        guard !Task.isCancelled else { return }
        do {
          created = try await client.createSession(server, directory ?? "", newSessionID ?? "")
          sessionID = created?.id
        } catch is CancellationError {
          return
        } catch {
          let failure = ComposerSendFailure.classify(
            error as? OpenCodeClientError ?? OpenCodeClientError(.unreachable)
          )
          await emit(
            .composerSendResult(
              operationID: operationID,
              messageID: actual.messageID,
              result: .failed(created: nil, failure: failure)
            )
          )
          return
        }
      }
      guard let sessionID else {
        await emit(
          .composerSendResult(
            operationID: operationID,
            messageID: actual.messageID,
            result: .failed(created: created, failure: .definite)
          )
        )
        return
      }
      if isRetry, !reconciledRetry {
        let found = await reconcileMessage(
          messageID: send.messageID,
          sessionID: sessionID,
          server: server,
          client: client
        )
        switch found {
        case .found:
          await emit(
            .composerSendResult(
              operationID: operationID,
              messageID: send.messageID,
              result: .accepted(sessionID: sessionID, created: created)
            )
          )
          return
        case .unreadable:
          await emit(
            .composerSendResult(
              operationID: operationID,
              messageID: send.messageID,
              result: .unverified(created: created)
            )
          )
          return
        case .absent:
          await emit(
            .composerSendResult(
              operationID: operationID,
              messageID: send.messageID,
              result: .retryAbsent(created: created)
            )
          )
          return
        }
      }

      // A create or reconciliation may finish after the screen abandoned this operation. Never issue
      // the prompt mutation in that case.
      guard !Task.isCancelled else { return }
      do {
        try await client.sendPrompt(server, sessionID, actual.prompt)
        await emit(
          .composerSendResult(
            operationID: operationID,
            messageID: actual.messageID,
            result: .accepted(sessionID: sessionID, created: created)
          )
        )
      } catch is CancellationError {
        return
      } catch {
        let clientError = error as? OpenCodeClientError ?? OpenCodeClientError(.unreachable)
        let failure = ComposerSendFailure.classify(clientError)
        if failure == .definite {
          await emit(
            .composerSendResult(
              operationID: operationID,
              messageID: actual.messageID,
              result: .failed(created: created, failure: failure)
            )
          )
          return
        }
        let found = await reconcileMessage(
          messageID: actual.messageID,
          sessionID: sessionID,
          server: server,
          client: client
        )
        let result: ComposerSendResult
        switch found {
        case .found:
          result = .accepted(sessionID: sessionID, created: created)
        case .absent:
          result = .failed(created: created, failure: failure)
        case .unreadable:
          result = .unverified(created: created)
        }
        await emit(
          .composerSendResult(
            operationID: operationID,
            messageID: actual.messageID,
            result: result
          )
        )
      }
    }
    .cancellable(id: CancelID.composerSend(operationID), cancelInFlight: false)
  }

  private func composerSendResult(
    operationID: Int,
    messageID: String,
    result: ComposerSendResult,
    state: inout State
  ) -> Effect<Action> {
    guard let operation = state.composerSend, operation.id == operationID else { return .none }
    var effects: [Effect<Action>] = []
    if let created = operation.createdSession ?? createdSession(in: result) {
      adopt(created, state: &state)
      effects.append(.send(.composer(.sessionCreated(created.id))))
    }
    state.composerSend = nil
    let createdSession = operation.createdSession ?? createdSession(in: result)
    let outcomeTarget = createdSession.map { ComposerTarget.session(id: $0.id) }
      ?? operation.send.target
    let currentTarget = state.composer.target
    let matchesCurrent = currentTarget == operation.send.target
      || (createdSession.map { currentTarget == .session(id: $0.id) } == true)

    switch result {
    case .retryAbsent:
      removeOptimistic(operation.send, messageID: operation.send.messageID, state: &state)
      effects.append(
        .send(
          .composer(
            .retryMessageIDConfirmedAbsent(
              messageID: operation.send.messageID,
              createdSessionID: createdSession?.id
            )
          )
        )
      )
      AppLog(category: .send).event(
        .composerSent,
        [LogField("retryAbsent", .flag(true)), LogField("operation", .count(operationID))]
      )
      return .merge(effects)

    case .accepted(let sessionID, _):
      var accepted = operation.send
      accepted.messageID = messageID
      showOptimistic(accepted, messageID: messageID, sessionID: sessionID, state: &state)
      if matchesCurrent {
        effects.append(.send(.composer(.sendAccepted(messageID: messageID))))
      } else {
        effects.append(
          .send(
            .composer(
              .resolveOutbound(
                target: outcomeTarget,
                messageID: operation.send.messageID,
                resolution: .accepted
              )
            )
          )
        )
      }
      effects.append(
        waitForIdle(
          operationID: operationID,
          sessionID: sessionID,
          messageID: messageID,
          server: state.server
        )
      )
      AppLog(category: .send).event(
        .composerSent,
        [LogField("accepted", .flag(true)), LogField("operation", .count(operationID))]
      )
      return .merge(effects)

    case .failed(_, let failure):
      removeOptimistic(operation.send, messageID: messageID, state: &state)
      if matchesCurrent {
        effects.append(.send(.composer(.sendFailed(messageID: messageID, failure: failure))))
      } else {
        effects.append(
          .send(
            .composer(
              .resolveOutbound(
                target: outcomeTarget,
                messageID: operation.send.messageID,
                resolution: .failed(failure)
              )
            )
          )
        )
      }
      AppLog(category: .send).event(
        .composerSendFailed,
        [
          LogField("ambiguous", .flag(failure == .ambiguous)),
          LogField("operation", .count(operationID)),
        ]
      )
      return .merge(effects)

    case .unverified:
      if matchesCurrent {
        effects.append(.send(.composer(.sendUnverified(messageID: messageID))))
      } else {
        effects.append(
          .send(
            .composer(
              .resolveOutbound(
                target: outcomeTarget,
                messageID: operation.send.messageID,
                resolution: .unverified(.ambiguous)
              )
            )
          )
        )
      }
      effects.append(.send(.refreshRequested(.settlement(messageID: messageID))))
      AppLog(category: .send).event(
        .composerSendFailed,
        [
          LogField("ambiguous", .flag(true)),
          LogField("verified", .flag(false)),
        ]
      )
      return .merge(effects)
    }
  }

  private func createdSession(in result: ComposerSendResult) -> OpenCodeSession? {
    switch result {
    case .accepted(_, let created), .failed(let created, _), .unverified(let created),
      .retryAbsent(let created):
      return created
    }
  }

  private func waitForIdle(
    operationID: Int,
    sessionID: String,
    messageID: String,
    server: OpenCodeServer
  ) -> Effect<Action> {
    let client = client
    return .run { send in
      do {
        try await client.waitForIdle(server, sessionID)
        await send(
          .composerWaitFinished(operationID: operationID, sessionID: sessionID, messageID: messageID)
        )
      } catch is CancellationError {
        return
      } catch {
        // The stream and the next authoritative read still deliver the reply. A failed wait is not
        // a failed send.
        return
      }
    }
    .cancellable(id: CancelID.composerWait(operationID), cancelInFlight: false)
  }

  private func adoptRestoredSession(_ sessionID: String, state: inout State) -> Effect<Action> {
    guard state.composer.target.sessionID == sessionID || state.selection.sessionID == sessionID
    else { return .none }
    let client = client
    let server = state.server
    return .run { send in
      do {
        let session = try await client.getSession(server, sessionID)
        await send(.composerSessionLoaded(sessionID: sessionID, result: .success(session)))
      } catch is CancellationError {
        return
      } catch {
        await send(
          .composerSessionLoaded(
            sessionID: sessionID,
            result: .failure(error as? OpenCodeClientError ?? OpenCodeClientError(.unreachable))
          )
        )
      }
    }
    .cancellable(id: CancelID.composerSend(0), cancelInFlight: true)
  }

  private func adopt(_ session: OpenCodeSession, state: inout State) {
    guard state.isNewSessionDraft || state.selection.sessionID == session.id else { return }
    state.root = session
    state.selection = SessionSelection(
      serverID: state.server.persistenceID,
      sessionID: session.id,
      intent: .browse
    )
    state.family = SessionFamily(root: session, sessions: [session])
    state.pages = []
    state.isLoading = false
    state.loadProblem = nil
  }

  private func showOptimistic(
    _ send: ComposerSend,
    messageID: String,
    sessionID: String,
    state: inout State
  ) {
    guard !send.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !send.quotes.isEmpty
    else { return }
    var transcript = state.transcripts[sessionID] ?? TranscriptState(sessionID: sessionID)
    guard !transcript.items.contains(where: { $0.id == messageID }) else { return }
    transcript.items.append(
      .userText(
        id: messageID,
        text: send.text,
        source: nil,
        quotes: send.quotes.map(\.wire)
      )
    )
    state.transcripts[sessionID] = transcript
  }

  private func removeOptimistic(
    _ send: ComposerSend,
    messageID: String,
    state: inout State
  ) {
    for (sessionID, var transcript) in state.transcripts {
      if transcript.items.contains(where: { $0.id == messageID }) {
        transcript.items.removeAll { $0.id == messageID }
        state.transcripts[sessionID] = transcript
      }
    }
  }

  private enum MessageReconciliation {
    case found
    case absent
    case unreadable
  }

  private func reconcileMessage(
    messageID: String,
    sessionID: String,
    server: OpenCodeServer,
    client: OpenCodeClient
  ) async -> MessageReconciliation {
    do {
      let rows = try await client.message(server, sessionID, messageID)
      if !rows.isEmpty { return .found }
    } catch is CancellationError {
      return .unreadable
    } catch let error as OpenCodeClientError {
      if error.statusCode != 404 { return .unreadable }
    } catch {
      return .unreadable
    }
    do {
      let inbox = try await client.pendingInputs(server, sessionID)
      return inbox.contains(where: { $0.id == messageID }) ? .found : .absent
    } catch {
      return .unreadable
    }
  }

  // MARK: Pending inputs

  private func pendingInputSendNow(_ inputID: String, state: inout State) -> Effect<Action> {
    guard let input = state.pendingInputs.first(where: { $0.id == inputID }),
      !input.isCompaction
    else { return .none }
    if !state.isRunning {
      return strandedSteer(inputID: inputID, state: &state)
    }
    guard input.delivery == .queue, let sessionID = state.activeSessionID else { return .none }
    return changePendingInputDelivery(
      inputID,
      to: .steer,
      sessionID: sessionID,
      state: &state
    )
  }

  private func pendingInputQueue(_ inputID: String, state: inout State) -> Effect<Action> {
    guard let input = state.pendingInputs.first(where: { $0.id == inputID }),
      !input.isCompaction,
      let sessionID = state.activeSessionID
    else { return .none }
    if !state.isRunning, input.delivery == .steer {
      // Queueing a stranded message leaves it parked for the reader's next run.
      return changePendingInputDelivery(inputID, to: .queue, sessionID: sessionID, state: &state)
    }
    guard input.delivery == .steer else { return .none }
    return changePendingInputDelivery(inputID, to: .queue, sessionID: sessionID, state: &state)
  }

  private func changePendingInputDelivery(
    _ inputID: String,
    to delivery: PendingInput.Delivery,
    sessionID: String,
    state: inout State
  ) -> Effect<Action> {
    guard let index = state.pendingInputs.firstIndex(where: { $0.id == inputID }) else {
      return .none
    }
    let previous = state.pendingInputs[index].delivery
    state.pendingInputs[index].delivery = delivery
    haptics.play(.tap)
    let client = client
    let server = state.server
    return .run { send in
      do {
        try await client.setPendingInputDelivery(server, sessionID, inputID, delivery)
        await send(
          .pendingInputDeliveryFinished(
            sessionID: sessionID,
            inputID: inputID,
            previous: previous,
            result: .success(true)
          )
        )
      } catch is CancellationError {
        return
      } catch {
        await send(
          .pendingInputDeliveryFinished(
            sessionID: sessionID,
            inputID: inputID,
            previous: previous,
            result: .failure(
              error as? OpenCodeClientError ?? OpenCodeClientError(.unreachable)
            )
          )
        )
      }
    }
    .cancellable(id: CancelID.pendingInput(inputID), cancelInFlight: true)
  }

  private func pendingInputCancel(_ inputID: String, state: inout State) -> Effect<Action> {
    guard state.pendingInputs.contains(where: { $0.id == inputID }),
      let sessionID = state.activeSessionID
    else { return .none }
    haptics.play(.tap)
    let client = client
    let server = state.server
    return .run { send in
      do {
        try await client.cancelPendingInput(server, sessionID, inputID)
        await send(
          .pendingInputCancelFinished(sessionID: sessionID, inputID: inputID, result: .success(true))
        )
      } catch is CancellationError {
        return
      } catch {
        await send(
          .pendingInputCancelFinished(
            sessionID: sessionID,
            inputID: inputID,
            result: .failure(
              error as? OpenCodeClientError ?? OpenCodeClientError(.unreachable)
            )
          )
        )
      }
    }
    .cancellable(id: CancelID.pendingInput(inputID), cancelInFlight: true)
  }

  // MARK: Request dock

  private func sendRequestBar(state: inout State) -> Effect<Action> {
    guard let id = state.requests.selectedRequestID,
      !state.requests.respondingIDs.contains(id)
    else { return .none }
    if let permission = state.requests.permission(id) {
      let reason = state.requestDock.answerText(for: state.requests)
      return replyPermission(
        id: id,
        decision: .reject,
        message: reason.isEmpty ? nil : reason,
        state: &state
      )
    }
    guard let form = state.requests.form(id) else { return .none }
    guard form.fitsDock else {
      state.requestDock.showsSheet = true
      return .none
    }
    var dock = state.requestDock
    let requests = state.requests
    dock.answerChanged(
      dock.answerText(for: requests),
      request: requests,
      answers: &state.requests.answers
    )
    state.requestDock = dock
    let answers = state.requests.answers[id] ?? form.defaultAnswers
    guard let selected = state.requestDock.field(for: form, answers: answers) else {
      return submitForm(id, state: &state)
    }
    let ready = hasAnswer(answers[selected.field.key])
    if !ready, selected.page >= selected.count - 1 {
      return submitForm(id, state: &state)
    }
    if !ready { return .none }
    if selected.page < selected.count - 1 {
      state.requestDock.questionPages[id] = selected.page + 1
      return .none
    }
    return submitForm(id, state: &state)
  }

  private func hasAnswer(_ value: FormValue?) -> Bool {
    switch value {
    case .string(let text): !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .strings(let values): !values.isEmpty
    case .number, .boolean: true
    case nil: false
    }
  }

  private func syncRequestDock(_ state: inout State) {
    guard state.requests.hasPending else {
      state.requestDock.clearAnswers()
      state.requestDock.showsSheet = false
      return
    }
    if let id = state.requests.selectedRequestID, let form = state.requests.form(id) {
      let answers = state.requests.answers[id] ?? form.defaultAnswers
      if let selected = state.requestDock.field(for: form, answers: answers) {
        state.requestDock.questionPages[id] = selected.page
      }
    }
  }
}

extension RefreshReason {
  /// Metadata, family, requests, shells and jobs. The lighter reasons read only what a run or request
  /// change can affect.
  var readsFamily: Bool {
    switch self {
    case .open, .resume, .reconnect, .watchdog, .snapshot, .recovery: true
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
    return .merge(
      abandon,
      requestRefresh(.resume, state: &state),
      .send(.composer(.switchTarget(.session(id: session.id))))
    )
  }

  private func popPage(state: inout State) -> Effect<Action> {
    guard let leaving = state.pages.popLast() else { return .none }
    state.selectionByPage[leaving.id] = nil
    restoreSelection(pageID: state.activePage?.id ?? 0, state: &state)
    state.isLoading = true
    let abandon = abandonRefresh(&state)
    let target = activeTarget(state: state)
    return .merge(
      abandon,
      requestRefresh(.resume, state: &state),
      target.map { .send(.composer(.switchTarget($0))) } ?? .none
    )
  }

  /// A page change invalidates the read started for the old page rather than letting it finish
  /// against a different active session.
  private func abandonRefresh(_ state: inout State) -> Effect<Action> {
    state.refresh = nil
    if let sessionID = state.activeSessionID, var transcript = state.transcripts[sessionID],
      case .loading(let cursor, let reached) = transcript.earlier
    {
      transcript.earlier = reached ? .paging(cursor: cursor) : .seekingOverlap(cursor: cursor)
      state.transcripts[sessionID] = transcript
    }
    return .merge(
      .cancel(id: CancelID.refresh),
      .cancel(id: CancelID.transcriptEarlier),
      .cancel(id: CancelID.recoveryRetry)
    )
  }

  private func restoreSelection(pageID: Int, state: inout State) {
    state.requests.selectedID = state.selectionByPage[pageID] ?? nil
  }

  private func activeTarget(state: State) -> ComposerTarget? {
    if let id = state.activeSessionID { return .session(id: id) }
    if state.composer.target.isNewSession { return state.composer.target }
    return nil
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
    syncRequestDock(&state)
  }

  private func pruneRequest(_ id: String, state: inout State) {
    state.requests.permissions.removeAll { $0.id == id }
    state.requests.forms.removeAll { $0.id == id }
    state.requests.answers[id] = nil
    if state.requests.selectedID == id {
      state.requests.selectedID = state.requests.reviewIDs.first
      state.selectionByPage[state.activePage?.id ?? 0] = state.requests.selectedID
    }
    syncRequestDock(&state)
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
      let cursor = output.endCursor, !output.isUnavailable, !output.requiresDiscardConfirmation
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
    guard let start = output.endCursor else {
      output.isStopping = false
      output.requiresDiscardConfirmation = true
      output.problem = .unsupported
      state.background.output = output
      return .none
    }
    let client = client
    let server = state.server
    let shellID = output.shellID
    let size = output.size
    output.isStopping = true
    state.background.output = output
    return .run { send in
      var cursor = start
      var knownSize = size
      var pages = 0
      let maximumPages = 4_096
      do {
        // Cancellation observed before dispatch prevents the DELETE; a request already sent may
        // have an uncertain outcome. Every dependency return is checked because a transport call
        // can complete successfully after its task was cancelled.
        try Task.checkCancellation()
        // Stopping discards the server's capture: drain every remaining page first, with bounded
        // local retention. A failed or incomplete drain never reaches the delete. The capture can
        // grow while it drains, so the completion boundary is the size the probe reports once the
        // pages caught up.
        draining: while true {
          try Task.checkCancellation()
          while cursor < knownSize {
            guard pages < maximumPages else {
              await send(
                .shellDrainFailed(
                  shellID: shellID,
                  error: OpenCodeClientError(.undecodable(feature: "shell capture too large"))
                )
              )
              return
            }
            try Task.checkCancellation()
            let page = try await client.shellOutput(
              server, directory, shellID, cursor, ShellOutputState.pageBytes
            )
            try Task.checkCancellation()
            guard page.cursor > cursor else {
              await send(
                .shellDrainFailed(
                  shellID: shellID,
                  error: OpenCodeClientError(.undecodable(feature: "shell output cursor"))
                )
              )
              return
            }
            await send(.shellDrainPage(shellID: shellID, page: page))
            cursor = page.cursor
            pages += 1
          }
          try Task.checkCancellation()
          let probe = try await client.shellOutput(
            server, directory, shellID, Int.max, 1
          )
          try Task.checkCancellation()
          if probe.size <= cursor { break draining }
          knownSize = probe.size
        }
        try Task.checkCancellation()
        try await client.stopShell(server, directory, shellID)
        await send(.shellStopFinished(shellID: shellID, error: nil))
      } catch is CancellationError {
        return
      } catch let error as OpenCodeClientError {
        await send(.shellDrainFailed(shellID: shellID, error: error))
      } catch {
        await send(.shellDrainFailed(shellID: shellID, error: OpenCodeClientError(.unreachable)))
      }
    }
    .cancellable(id: CancelID.shellStop(shellID), cancelInFlight: true)
  }

  /// The person chose to discard output the drain could not finish.
  private func discardUnreadAndStopShell(state: inout State) -> Effect<Action> {
    guard let output = state.background.output,
      let directory = state.activeSession?.directory ?? state.root?.directory
    else { return .none }
    let client = client
    let server = state.server
    let shellID = output.shellID
    return .run { send in
      do {
        // The explicit discard is also bounded by cancellation before dispatch; once the DELETE is
        // sent its outcome is uncertain and is treated as the normal request failure path.
        try Task.checkCancellation()
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

  private func trimShellOutput(
    _ text: String,
    limit: Int
  ) -> (text: String, discardedBytes: Int) {
    let bytes = Array(text.utf8)
    guard bytes.count > limit else { return (text, 0) }
    var cut = bytes.count - limit
    let searchEnd = min(cut + 4_096, bytes.count)
    if let newline = bytes[cut..<searchEnd].firstIndex(of: 0x0A) {
      cut = newline + 1
    } else {
      while cut < bytes.count, bytes[cut] & 0xC0 == 0x80 { cut += 1 }
    }
    return (String(decoding: bytes[cut...], as: UTF8.self), cut)
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

extension SessionFeature {
  // MARK: Transcript

  private func applyTranscript(
    _ page: TranscriptPage,
    for sessionID: String,
    state: inout State
  ) {
    var transcript = state.transcripts[sessionID]
      ?? TranscriptState(sessionID: sessionID)
    let complete = page.next == nil
    let existingIDs = Set(transcript.items.map(\.id))
    let windowIDs = Set(page.items.map(\.id))
    let firstFetchedIsKnown = page.items.first.map { existingIDs.contains($0.id) } ?? true
    let lostOverlap =
      !complete && !transcript.items.isEmpty && !page.items.isEmpty && !firstFetchedIsKnown
    if complete || lostOverlap {
      transcript.generation += 1
      transcript.earlier = complete ? .exhausted : .unknownEdge
      transcript.insertionAnchorID = nil
      if case .loading = transcript.earlier { transcript.earlier = .unknownEdge }
    }
    transcript.items = TranscriptProjection.mergeNewest(
      fetched: page.items,
      existing: transcript.items,
      complete: complete
    )
    transcript.problem = nil
    transcript.didApplyWindow = true
    transcript.initialLoaded = true
    if complete {
      transcript.earlier = .exhausted
      transcript.earlierProblem = nil
    }
    if !complete, page.next != nil, transcript.earlier == .unknownEdge,
      transcript.items.count <= page.items.count
    {
      // The first window did not reach the start: the next tap can page from its cursor.
      transcript.earlier = .paging(cursor: page.next)
      transcript.insertionAnchorID = page.items.first?.id
    }
    if transcript.isFollowing { transcript.showsJumpToLatest = false }
    state.transcripts[sessionID] = transcript
    AppLog(category: .app).event(
      .transcriptLoaded,
      [
        LogField("rows", .count(page.items.count)),
        LogField("complete", .flag(complete)),
      ]
    )
  }

  private func applyTranscriptFailure(
    _ problem: SessionProblem,
    for sessionID: String,
    state: inout State
  ) {
    var transcript = state.transcripts[sessionID]
      ?? TranscriptState(sessionID: sessionID)
    if transcript.items.isEmpty {
      transcript.problem = problem
      transcript.didApplyWindow = true
    }
    state.transcripts[sessionID] = transcript
  }

  private func applyLiveTranscript(
    _ events: [LiveContentEvent],
    for sessionID: String,
    state: inout State
  ) {
    guard state.root?.id == sessionID
      || state.family?.sessions.contains(where: { $0.id == sessionID }) == true
      || state.pages.contains(where: { $0.sessionID == sessionID })
    else { return }
    var transcript = state.transcripts[sessionID]
      ?? TranscriptState(sessionID: sessionID)
    TranscriptProjection.apply(events: events, to: &transcript.items)
    if transcript.isFollowing { transcript.showsJumpToLatest = false }
    state.transcripts[sessionID] = transcript
  }

  private func loadEarlierTranscript(state: inout State) -> Effect<Action> {
    guard let sessionID = state.activeSessionID,
      var transcript = state.transcripts[sessionID],
      !transcript.isLoadingEarlier,
      transcript.hasEarlierItems
    else { return .none }
    let cursor: String?
    let reachedLoadedItems: Bool
    switch transcript.earlier {
    case .unknownEdge:
      cursor = nil
      reachedLoadedItems = false
    case .seekingOverlap(let value):
      cursor = value
      reachedLoadedItems = false
    case .paging(let value):
      cursor = value
      reachedLoadedItems = true
    case .loading, .exhausted:
      return .none
    }
    transcript.earlier = .loading(cursor: cursor, reachedLoadedItems: reachedLoadedItems)
    transcript.earlierProblem = nil
    let generation = transcript.generation
    state.transcripts[sessionID] = transcript
    let server = state.server
    let client = client
    return .run { send in
      let result: Result<TranscriptPage, OpenCodeClientError>
      do {
        result = .success(try await client.transcriptHistory(server, sessionID, cursor))
      } catch let error as OpenCodeClientError {
        result = .failure(error)
      } catch {
        result = .failure(OpenCodeClientError(.unreachable))
      }
      await send(
        .transcriptEarlierFinished(
          sessionID: sessionID,
          generation: generation,
          cursor: cursor,
          result: result
        )
      )
    }
    .cancellable(id: CancelID.transcriptEarlier, cancelInFlight: true)
  }

  private func earlierTranscriptFinished(
    sessionID: String,
    generation: Int,
    cursor: String?,
    result: Result<TranscriptPage, OpenCodeClientError>,
    state: inout State
  ) -> Effect<Action> {
    guard var transcript = state.transcripts[sessionID],
      transcript.generation == generation,
      case .loading(let loadingCursor, let reachedLoadedItems) = transcript.earlier,
      loadingCursor == cursor
    else { return .none }

    switch result {
    case .failure(let error):
      transcript.earlier =
        reachedLoadedItems ? .paging(cursor: cursor) : .seekingOverlap(cursor: cursor)
      transcript.earlierProblem = .from(error, isOffline: !state.isLive)
      state.transcripts[sessionID] = transcript
      AppLog(category: .app).event(
        .transcriptEarlierLoaded,
        [LogField("status", .status(error.statusCode ?? 0))]
      )
      return .none

    case .success(let page):
      if let next = page.next, next == cursor {
        transcript.earlier =
          reachedLoadedItems ? .paging(cursor: cursor) : .seekingOverlap(cursor: cursor)
        transcript.earlierProblem = .malformed(feature: "transcript history")
        state.transcripts[sessionID] = transcript
        return .none
      }
      let merged = TranscriptProjection.mergeOlder(
        page: page.items,
        existing: transcript.items,
        insertionAnchorID: transcript.insertionAnchorID,
        reachedLoadedItems: reachedLoadedItems
      )
      if let merged {
        transcript.items = merged
        transcript.insertionAnchorID = page.items.first?.id ?? transcript.insertionAnchorID
        transcript.earlier = page.next.map { .paging(cursor: $0) } ?? .exhausted
        transcript.earlierProblem = nil
        transcript.problem = nil
      } else if page.next == nil, !page.items.isEmpty {
        transcript.earlier = .seekingOverlap(cursor: nil)
        transcript.earlierProblem = .malformed(feature: "transcript history")
      } else {
        transcript.earlier = page.next.map { .seekingOverlap(cursor: $0) } ?? .exhausted
      }
      state.transcripts[sessionID] = transcript
      AppLog(category: .app).event(
        .transcriptEarlierLoaded,
        [
          LogField("rows", .count(page.items.count)),
          LogField("exhausted", .flag(transcript.earlier == .exhausted)),
        ]
      )
      return .none
    }
  }
}
