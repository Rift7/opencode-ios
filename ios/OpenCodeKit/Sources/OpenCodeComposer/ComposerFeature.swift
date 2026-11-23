import ComposableArchitecture
import Foundation
import OpenCodeCore
import OpenCodeServer

/// The composer's own state: text, quotes, send eligibility, persistence and recoverable failures.
/// It never reads the transcript and never owns a server read; the session feature handles sending
/// and navigates the result back here.
@Reducer
public struct ComposerFeature: Sendable {
  @ObservableState
  public struct State: Equatable, Sendable {
    public let serverID: String
    public var target: ComposerTarget
    public var draft: String
    public var quotes: [ComposerQuote]
    public var delivery: Delivery
    public var focusRequest: Int
    public var isFocused: Bool
    public var isSending: Bool
    public var isRestoring: Bool
    public var problem: ComposerProblem?
    public var failedSends: [FailedComposerSend]
    /// Persisted before dispatch. At most one operation is in flight; an unresolved record restored
    /// from disk becomes a failed ambiguous send and is never replayed as ordinary text.
    public var outbound: [ComposerOutbound]

    /// Typing and quote edits bump this, so a send that started earlier cannot clear newer text.
    public var revision: Int
    /// Every durable-content change bumps this; a late transfer may not replace a newer record.
    public var contentRevision: Int
    /// Wall-clock content time, used across sessions whose revisions restarted.
    public var contentUpdatedAt: Date
    var restoreToken: Int
    var saveGeneration: Int
    var pendingDispatch: PendingDispatch?
    /// An ambiguous retry whose prompt was dispatched under a recorded ID and is waiting for
    /// reconciliation. It owns the payload until the ID is confirmed present or absent.
    var retryDispatch: PendingDispatch?
    var dispatchGeneration: Int?
    var switchToken: Int
    var flushToken: Int
    var flushRequestID: UUID?
    var parkedDrafts: [ComposerDraftKey: ComposerDraft]

    struct PendingDispatch: Equatable, Sendable {
      var send: ComposerSend
      var retryFailure: ComposerSendFailure?
      /// The identity the last durable record used when this dispatch replaced it.
      var restoreMessageID: String?
      var restoreFailure: ComposerSendFailure?
    }

    public init(
      serverID: String,
      target: ComposerTarget,
      draft: String = "",
      quotes: [ComposerQuote] = []
    ) {
      self.serverID = serverID
      self.target = target
      self.draft = draft
      self.quotes = quotes
      self.delivery = .steer
      self.focusRequest = 0
      self.isFocused = false
      self.isSending = false
      self.isRestoring = false
      self.problem = nil
      self.failedSends = []
      self.outbound = []
      self.revision = 0
      self.contentRevision = 0
      self.contentUpdatedAt = Date(timeIntervalSince1970: 0)
      self.restoreToken = 0
      self.saveGeneration = 0
      self.pendingDispatch = nil
      self.retryDispatch = nil
      self.dispatchGeneration = nil
      self.switchToken = 0
      self.flushToken = 0
      self.flushRequestID = nil
      self.parkedDrafts = [:]
    }

    public var draftKey: ComposerDraftKey {
      ComposerDraftKey(serverID: serverID, scope: target.scope)
    }

    /// Starts a new composer above a departing draft's revision/time so later typing in the same
    /// key always supersedes a transfer that is still in flight.
    public mutating func raiseContentWatermark(revision: Int, updatedAt: Date) {
      contentRevision = max(contentRevision, revision)
      contentUpdatedAt = max(contentUpdatedAt, updatedAt)
    }

    public var canSend: Bool {
      !isSending && outbound.isEmpty
        && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !quotes.isEmpty)
    }

    public var isEmpty: Bool {
      draft.isEmpty && quotes.isEmpty && failedSends.isEmpty && outbound.isEmpty
    }

    /// The complete durable composer record, including outbound ownership and failed sends.
    public var persistedDraft: ComposerDraft {
      ComposerDraft(
        text: draft,
        quotes: quotes,
        projectDirectory: target.directory,
        createdSessionID: target.isNewSession ? nil : target.sessionID,
        failedSends: failedSends,
        outbound: outbound,
        revision: contentRevision,
        updatedAt: contentUpdatedAt
      )
    }
  }

  public enum Action: Equatable, Sendable {
    case task
    case restoreRetried
    case textChanged(String)
    case focusChanged(Bool)
    case focusRequested
    case quoteInserted(text: String)
    case quoteCommentChanged(id: String, comment: String)
    case quoteRemoved(id: String)
    case sendTapped
    case queueTapped
    case outboundPersisted(messageID: String)
    case sendAccepted(messageID: String)
    case sendBlocked(ComposerProblem)
    case sendFailed(messageID: String, failure: ComposerSendFailure)
    /// The POST may have landed and the read-back could not settle it. Keep the optimistic row and
    /// the outbound record; a later Retry or authoritative read reconciles it.
    case sendUnverified(messageID: String)
    case retryFailed(messageID: String)
    /// Reconciliation confirmed the ambiguous retry never landed. Replace the recorded identity
    /// durably before the prompt is issued again.
    case retryMessageIDConfirmedAbsent(messageID: String, createdSessionID: String?)
    case editFailed(messageID: String)
    case deleteFailed(messageID: String)
    case sessionCreated(String)
    case migrationFinished(
      result: ComposerDraftMigration,
      draft: ComposerDraft,
      oldKey: ComposerDraftKey,
      newKey: ComposerDraftKey
    )
    case retryMigrationFinished(
      result: ComposerDraftMigration,
      send: ComposerSend,
      newKey: ComposerDraftKey
    )
    case resolveOutbound(
      target: ComposerTarget,
      messageID: String,
      resolution: ComposerOutboundResolution
    )
    case switchTarget(ComposerTarget)
    case targetSwitchFinished(
      token: Int,
      target: ComposerTarget,
      oldKey: ComposerDraftKey,
      oldDraft: ComposerDraft,
      result: ComposerDraftSave
    )
    case flush
    case flushForDismiss(UUID)
    case flushSaved(
      requestID: UUID,
      token: Int,
      draft: ComposerDraft,
      result: ComposerDraftSave
    )
    case draftLoaded(token: Int, key: ComposerDraftKey, outcome: ComposerDraftLoad)
    case saveDue(generation: Int, key: ComposerDraftKey, draft: ComposerDraft, remove: Bool)
    case saveFinished(generation: Int, key: ComposerDraftKey, result: ComposerDraftSave)
    case delegate(Delegate)
  }

  public enum Delegate: Equatable, Sendable {
    case send(ComposerSend)
    case retry(FailedComposerSend)
    case restoredCreatedSession(String)
    case flushForDismissFinished(requestID: UUID, result: ComposerDraftSave)
  }

  enum CancelID: Hashable {
    case save
    case restore
  }

  @Dependency(\.clock) private var clock
  @Dependency(\.dateClient) private var date
  @Dependency(\.uuidClient) private var uuid
  @Dependency(\.haptics) private var haptics
  @Dependency(\.composerDrafts) private var drafts

  public init() {}

  public var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        guard !state.isRestoring else { return .none }
        return loadDraft(state: &state)

      case .restoreRetried:
        return loadDraft(state: &state)

      case .textChanged(let text):
        guard text != state.draft else { return .none }
        state.draft = text
        state.revision += 1
        state.contentRevision += 1
        state.contentUpdatedAt = max(state.contentUpdatedAt, date.now())
        state.isRestoring = false
        state.problem = nil
        return scheduleSave(state: &state)

      case .focusChanged(let focused):
        state.isFocused = focused
        return .none

      case .focusRequested:
        state.focusRequest += 1
        return .none

      case .quoteInserted(let text):
        guard let cleaned = ComposerQuote.cleaned(text) else { return .none }
        state.quotes.append(ComposerQuote(text: cleaned))
        state.revision += 1
        state.contentRevision += 1
        state.contentUpdatedAt = max(state.contentUpdatedAt, date.now())
        state.isRestoring = false
        state.problem = nil
        state.focusRequest += 1
        haptics.play(.selection)
        return scheduleSave(state: &state)

      case .quoteCommentChanged(let id, let comment):
        guard let index = state.quotes.firstIndex(where: { $0.id == id }) else { return .none }
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        state.quotes[index].comment = trimmed.isEmpty ? nil : trimmed
        state.revision += 1
        state.contentRevision += 1
        state.contentUpdatedAt = max(state.contentUpdatedAt, date.now())
        return scheduleSave(state: &state)

      case .quoteRemoved(let id):
        guard state.quotes.contains(where: { $0.id == id }) else { return .none }
        state.quotes.removeAll { $0.id == id }
        state.revision += 1
        state.contentRevision += 1
        state.contentUpdatedAt = max(state.contentUpdatedAt, date.now())
        return scheduleSave(state: &state)

      case .sendTapped:
        guard state.canSend, let send = makeSend(delivery: .steer, state: state) else {
          return .none
        }
        haptics.play(.tap)
        return begin(send, retryFailure: nil, state: &state)

      case .queueTapped:
        guard state.canSend, let send = makeSend(delivery: .queue, state: state) else {
          return .none
        }
        haptics.play(.tap)
        return begin(send, retryFailure: nil, state: &state)

      case .outboundPersisted(let messageID):
        return dispatchPersisted(messageID: messageID, state: &state)

      case .sendAccepted(let messageID):
        guard state.outbound.contains(where: { $0.messageID == messageID }) else { return .none }
        state.isSending = false
        if state.pendingDispatch?.send.messageID == messageID {
          state.pendingDispatch = nil
          state.dispatchGeneration = nil
        }
        if state.retryDispatch?.send.messageID == messageID { state.retryDispatch = nil }
        state.outbound.removeAll { $0.messageID == messageID }
        state.problem = nil
        state.contentRevision += 1
        state.contentUpdatedAt = max(state.contentUpdatedAt, date.now())
        return scheduleSave(state: &state)

      case .sendUnverified(let messageID):
        guard let outbound = state.outbound.first(where: { $0.messageID == messageID }) else {
          return .none
        }
        state.isSending = false
        if state.pendingDispatch?.send.messageID == messageID {
          state.pendingDispatch = nil
          state.dispatchGeneration = nil
        }
        if state.retryDispatch?.send.messageID == messageID { state.retryDispatch = nil }
        state.problem = .couldNotVerifySend
        state.failedSends.append(
          FailedComposerSend(
            messageID: outbound.messageID,
            text: outbound.text,
            quotes: outbound.quotes,
            delivery: outbound.delivery,
            target: outbound.target,
            reason: .couldNotVerifySend,
            failure: .ambiguous
          )
        )
        state.outbound.removeAll { $0.messageID == outbound.messageID }
        state.contentRevision += 1
        state.contentUpdatedAt = max(state.contentUpdatedAt, date.now())
        haptics.play(.warning)
        return persistNow(state: &state)

      case .sendBlocked(let problem):
        return settleBlocked(problem, state: &state)

      case .sendFailed(let messageID, let failure):
        guard let outbound = state.outbound.first(where: { $0.messageID == messageID }) else {
          return .none
        }
        state.isSending = false
        if state.pendingDispatch?.send.messageID == messageID {
          state.pendingDispatch = nil
          state.dispatchGeneration = nil
        }
        if state.retryDispatch?.send.messageID == messageID { state.retryDispatch = nil }
        state.problem = failure == .ambiguous ? .couldNotVerifySend : .couldNotSend
        haptics.play(.error)
        state.outbound.removeAll { $0.messageID == outbound.messageID }
        if state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, state.quotes.isEmpty {
          state.draft = outbound.text
          state.quotes = outbound.quotes
          state.revision += 1
          state.focusRequest += 1
        } else {
          state.failedSends.append(
            FailedComposerSend(
              messageID: messageID,
              text: outbound.text,
              quotes: outbound.quotes,
              delivery: outbound.delivery,
              target: outbound.target,
              reason: state.problem ?? .couldNotSend,
              failure: failure
            )
          )
        }
        state.contentRevision += 1
        state.contentUpdatedAt = max(state.contentUpdatedAt, date.now())
        return persistNow(state: &state)

      case .retryFailed(let messageID):
        guard !state.isSending, state.outbound.isEmpty,
          let failed = state.failedSends.first(where: { $0.messageID == messageID })
        else { return .none }
        state.failedSends.removeAll { $0.messageID == messageID }
        state.contentRevision += 1
        state.contentUpdatedAt = max(state.contentUpdatedAt, date.now())
        haptics.play(.tap)
        let retryID = failed.failure == .definite
          ? uuid.uuid().uuidString.lowercased()
          : failed.messageID
        let target = failed.target.isNewSession && !state.target.isNewSession
          ? state.target
          : failed.target
        let send = ComposerSend(
          target: target,
          messageID: retryID,
          text: failed.text,
          quotes: failed.quotes,
          delivery: failed.delivery,
          revision: state.revision
        )
        return begin(
          send,
          retryFailure: failed.failure == .definite ? nil : failed.failure,
          restoreMessageID: failed.messageID,
          state: &state
        )

      case .retryMessageIDConfirmedAbsent(let messageID, let createdSessionID):
        return reidentifyAndDispatch(
          messageID: messageID,
          createdSessionID: createdSessionID,
          state: &state
        )

      case .editFailed(let messageID):
        guard let failed = state.failedSends.first(where: { $0.messageID == messageID }),
          failed.failure == .definite
        else { return .none }
        state.failedSends.removeAll { $0.messageID == messageID }
        let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? failed.text
          : failed.text + "\n\n" + state.draft
        state.draft = text
        state.quotes = failed.quotes + state.quotes
        state.revision += 1
        state.contentRevision += 1
        state.contentUpdatedAt = max(state.contentUpdatedAt, date.now())
        state.problem = nil
        state.focusRequest += 1
        return persistNow(state: &state)

      case .deleteFailed(let messageID):
        guard state.failedSends.contains(where: { $0.messageID == messageID }) else {
          return .none
        }
        state.failedSends.removeAll { $0.messageID == messageID }
        state.contentRevision += 1
        state.contentUpdatedAt = max(state.contentUpdatedAt, date.now())
        if state.failedSends.isEmpty { state.problem = nil }
        return persistNow(state: &state)

      case .sessionCreated(let sessionID):
        return migrateToCreatedSession(sessionID, state: &state)

      case .migrationFinished(let result, _, let oldKey, let newKey):
        guard state.target.scope == newKey.scope else { return .none }
        switch result {
        case .migrated:
          break
        case .destinationFailed:
          state.problem = .couldNotSave
        case .sourceRetained:
          state.problem = .couldNotCleanUpDraft
        }
        _ = oldKey
        return .none

      case .retryMigrationFinished(let result, let send, let newKey):
        guard state.target.scope == newKey.scope,
          state.pendingDispatch?.send.messageID == send.messageID
        else { return .none }
        switch result {
        case .migrated:
          return .send(.outboundPersisted(messageID: send.messageID))
        case .sourceRetained:
          state.problem = .couldNotCleanUpDraft
          return .send(.outboundPersisted(messageID: send.messageID))
        case .destinationFailed:
          restoreDispatchFailure(.couldNotSave, state: &state)
          return .none
        }

      case .resolveOutbound(let target, let messageID, let resolution):
        return resolveOutbound(
          serverID: state.serverID,
          target: target,
          messageID: messageID,
          resolution: resolution
        )

      case .switchTarget(let target):
        return switchTarget(target, state: &state)

      case .targetSwitchFinished(let token, _, _, _, let result):
        guard token == state.switchToken else { return .none }
        switch result {
        case .saved:
          break
        case .tooLarge:
          state.problem = .draftTooLarge
        case .failure:
          state.problem = .couldNotSave
        }
        return .none

      case .flush:
        return persistNow(state: &state)

      case .flushForDismiss(let requestID):
        return beginFlushForDismiss(requestID: requestID, state: &state)

      case .flushSaved(let requestID, let token, let draft, let result):
        return flushSaved(
          requestID: requestID,
          token: token,
          draft: draft,
          result: result,
          state: &state
        )

      case .draftLoaded(let token, let key, let outcome):
        return draftLoaded(token: token, key: key, outcome: outcome, state: &state)

      case .saveDue(let generation, let key, let draft, let remove):
        guard generation == state.saveGeneration, key == state.draftKey else { return .none }
        return .run { [drafts] send in
          let result: ComposerDraftSave
          if remove {
            result = await drafts.remove(key)
          } else {
            result = await drafts.save(draft, key)
          }
          await send(.saveFinished(generation: generation, key: key, result: result))
        }

      case .saveFinished(let generation, let key, let result):
        return saveFinished(generation: generation, key: key, result: result, state: &state)

      case .delegate:
        return .none
      }
    }
  }

  private func makeSend(delivery: Delivery, state: State) -> ComposerSend? {
    let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty || !state.quotes.isEmpty else { return nil }
    return ComposerSend(
      target: state.target,
      messageID: uuid.uuid().uuidString.lowercased(),
      text: text,
      quotes: state.quotes,
      delivery: delivery,
      revision: state.revision
    )
  }

  private func begin(
    _ send: ComposerSend,
    retryFailure: ComposerSendFailure?,
    restoreMessageID: String? = nil,
    state: inout State
  ) -> Effect<Action> {
    guard !state.isSending, state.outbound.isEmpty else { return .none }
    state.isSending = true
    state.problem = nil
    state.retryDispatch = nil
    state.pendingDispatch = State.PendingDispatch(
      send: send,
      retryFailure: retryFailure,
      restoreMessageID: restoreMessageID,
      restoreFailure: retryFailure
    )
    state.outbound = [
      ComposerOutbound(
        target: send.target,
        messageID: send.messageID,
        text: send.text,
        quotes: send.quotes,
        delivery: send.delivery,
        revision: send.revision,
        createdAt: date.now()
      )
    ]
    state.contentRevision += 1
    state.contentUpdatedAt = max(state.contentUpdatedAt, date.now())
    return persistNow(state: &state)
  }

  private func dispatchPersisted(messageID: String, state: inout State) -> Effect<Action> {
    guard let pending = state.pendingDispatch, pending.send.messageID == messageID else {
      return .none
    }
    state.pendingDispatch = nil
    state.dispatchGeneration = nil
    state.retryDispatch = pending.retryFailure == nil ? nil : pending
    state.isSending = true
    if state.revision == pending.send.revision {
      state.draft = ""
      state.quotes = []
      state.revision += 1
      state.contentRevision += 1
      state.contentUpdatedAt = max(state.contentUpdatedAt, date.now())
    }
    let save = pending.retryFailure == nil ? scheduleSave(state: &state) : .none
    if let failure = pending.retryFailure {
      let failed = FailedComposerSend(
        messageID: pending.send.messageID,
        text: pending.send.text,
        quotes: pending.send.quotes,
        delivery: pending.send.delivery,
        target: pending.send.target,
        reason: failure == .ambiguous ? .couldNotVerifySend : .couldNotSend,
        failure: failure
      )
      return .merge(.send(.delegate(.retry(failed))), save)
    }
    return .merge(.send(.delegate(.send(pending.send))), save)
  }

  private func settleBlocked(_ problem: ComposerProblem, state: inout State) -> Effect<Action> {
    let pending = state.pendingDispatch
    state.isSending = false
    state.pendingDispatch = nil
    state.retryDispatch = nil
    state.dispatchGeneration = nil
    state.problem = problem
    guard let outbound = state.outbound.first else {
      return persistNow(state: &state)
    }
    state.outbound.removeAll { $0.messageID == outbound.messageID }
    state.contentRevision += 1
    state.contentUpdatedAt = max(state.contentUpdatedAt, date.now())
    if state.target.scope != outbound.target.scope {
      return .merge(
        persistNow(state: &state),
        .send(
          .resolveOutbound(
            target: outbound.target,
            messageID: outbound.messageID,
            resolution: .failed(pending?.restoreFailure ?? .definite)
          )
        )
      )
    }
    let failure = pending?.restoreFailure ?? .definite
    if failure != .ambiguous,
      state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      state.quotes.isEmpty
    {
      state.draft = outbound.text
      state.quotes = outbound.quotes
      state.revision += 1
      state.focusRequest += 1
    } else {
      state.failedSends.append(
        FailedComposerSend(
          messageID: pending?.restoreMessageID ?? outbound.messageID,
          text: outbound.text,
          quotes: outbound.quotes,
          delivery: outbound.delivery,
          target: outbound.target,
          reason: problem,
          failure: failure
        )
      )
    }
    return persistNow(state: &state)
  }

  private func reidentifyAndDispatch(
    messageID: String,
    createdSessionID: String?,
    state: inout State
  ) -> Effect<Action> {
    guard let retry = state.retryDispatch, retry.send.messageID == messageID,
      state.outbound.contains(where: { $0.messageID == messageID })
    else { return .none }
    state.retryDispatch = nil
    var reidentified = retry.send
    reidentified.messageID = uuid.uuid().uuidString.lowercased()

    if let created = createdSessionID, state.target.isNewSession {
      let oldKey = state.draftKey
      var sourceDraft = snapshot(state)
      sourceDraft.createdSessionID = created
      let savedSource = sourceDraft
      state.target = .session(id: created)
      reidentified.target = .session(id: created)
      state.contentRevision += 1
      state.contentUpdatedAt = max(state.contentUpdatedAt, date.now())
      state.outbound = [outbound(for: reidentified)]
      state.pendingDispatch = State.PendingDispatch(
        send: reidentified,
        retryFailure: nil,
        restoreMessageID: messageID,
        restoreFailure: .ambiguous
      )
      state.contentRevision += 1
      state.contentUpdatedAt = max(state.contentUpdatedAt, date.now())
      state.isSending = true
      state.saveGeneration += 1
      state.dispatchGeneration = state.saveGeneration
      let newKey = state.draftKey
      var newDraft = snapshot(state)
      newDraft.createdSessionID = created
      let savedDestination = newDraft
      let finalSend = reidentified
      let drafts = drafts
      return .run { send in
        _ = await drafts.save(savedSource, oldKey)
        let result = await drafts.migrate(savedDestination, oldKey, newKey)
        await send(
          .retryMigrationFinished(
            result: result,
            send: finalSend,
            newKey: newKey
          )
        )
      }
    }

    state.outbound = [outbound(for: reidentified)]
    state.pendingDispatch = State.PendingDispatch(
      send: reidentified,
      retryFailure: nil,
      restoreMessageID: messageID,
      restoreFailure: .ambiguous
    )
    state.contentRevision += 1
    state.contentUpdatedAt = max(state.contentUpdatedAt, date.now())
    state.isSending = true
    return persistNow(state: &state)
  }

  private func outbound(for send: ComposerSend) -> ComposerOutbound {
    ComposerOutbound(
      target: send.target,
      messageID: send.messageID,
      text: send.text,
      quotes: send.quotes,
      delivery: send.delivery,
      revision: send.revision,
      createdAt: date.now()
    )
  }

  private func restoreDispatchFailure(_ problem: ComposerProblem, state: inout State) {
    guard let pending = state.pendingDispatch,
      let outbound = state.outbound.first(where: { $0.messageID == pending.send.messageID })
    else {
      state.isSending = false
      state.pendingDispatch = nil
      state.dispatchGeneration = nil
      state.problem = problem
      return
    }
    state.isSending = false
    state.pendingDispatch = nil
    state.dispatchGeneration = nil
    state.problem = problem
    state.outbound.removeAll { $0.messageID == outbound.messageID }
    state.contentRevision += 1
    state.contentUpdatedAt = max(state.contentUpdatedAt, date.now())
    let failure = pending.restoreFailure ?? .definite
    if failure != .ambiguous,
      state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      state.quotes.isEmpty
    {
      state.draft = outbound.text
      state.quotes = outbound.quotes
      state.revision += 1
      state.focusRequest += 1
    } else {
      state.failedSends.append(
        FailedComposerSend(
          messageID: pending.restoreMessageID ?? outbound.messageID,
          text: outbound.text,
          quotes: outbound.quotes,
          delivery: outbound.delivery,
          target: outbound.target,
          reason: problem,
          failure: failure
        )
      )
    }
  }

  private func saveFinished(
    generation: Int,
    key: ComposerDraftKey,
    result: ComposerDraftSave,
    state: inout State
  ) -> Effect<Action> {
    if generation == state.dispatchGeneration, let pending = state.pendingDispatch {
      state.dispatchGeneration = nil
      switch result {
      case .saved:
        return .send(.outboundPersisted(messageID: pending.send.messageID))
      case .tooLarge:
        restoreDispatchFailure(.draftTooLarge, state: &state)
        return .none
      case .failure:
        restoreDispatchFailure(.couldNotSave, state: &state)
        return .none
      }
    }
    guard generation == state.saveGeneration, key == state.draftKey else { return .none }
    switch result {
    case .saved:
      if state.problem == .couldNotSave || state.problem == .couldNotRestore
        || state.problem == .draftTooLarge || state.problem == .couldNotCleanUpDraft
      {
        state.problem = nil
      }
    case .tooLarge:
      state.problem = .draftTooLarge
    case .failure:
      state.problem = .couldNotSave
    }
    return .none
  }

  private func loadDraft(state: inout State) -> Effect<Action> {
    state.restoreToken += 1
    state.isRestoring = true
    let token = state.restoreToken
    let key = state.draftKey
    let parked = state.parkedDrafts[key]
    let sessionID = key.scope.sessionID
    let drafts = drafts
    return .run { send in
      var outcome = await drafts.load(key)
      if case .missing = outcome, let sessionID {
        outcome = await drafts.recoverCreated(sessionID, key)
      }
      if case .missing = outcome, let parked {
        outcome = .found(parked)
      }
      await send(.draftLoaded(token: token, key: key, outcome: outcome))
    }
    .cancellable(id: CancelID.restore, cancelInFlight: true)
  }

  private func draftLoaded(
    token: Int,
    key: ComposerDraftKey,
    outcome: ComposerDraftLoad,
    state: inout State
  ) -> Effect<Action> {
    guard token == state.restoreToken else { return .none }
    guard key == state.draftKey else {
      state.isRestoring = false
      return .none
    }
    state.isRestoring = false
    guard state.revision == 0, state.failedSends.isEmpty, state.outbound.isEmpty else {
      return .none
    }
    state.parkedDrafts[key] = nil
    switch outcome {
    case .missing:
      return .none
    case .failure:
      state.problem = .couldNotRestore
      return .none
    case .foundFromSource(let draft, .destinationFailed),
      .foundFromSource(let draft, .sourceRetained):
      state.problem = outcome.migrationProblem
      return apply(draft, state: &state)
    case .foundFromSource(let draft, .migrated):
      return apply(draft, state: &state)
    case .found(let draft):
      return apply(draft, state: &state)
    }
  }

  private func apply(_ draft: ComposerDraft, state: inout State) -> Effect<Action> {
    state.draft = draft.text
    state.quotes = draft.quotes
    state.failedSends = draft.failedSends
    state.outbound = []
    state.retryDispatch = nil
    state.contentRevision = max(state.contentRevision, draft.revision)
    state.contentUpdatedAt = max(state.contentUpdatedAt, draft.updatedAt)
    if let first = draft.outbound.first {
      state.failedSends.append(
        FailedComposerSend(
          messageID: first.messageID,
          text: first.text,
          quotes: first.quotes,
          delivery: first.delivery,
          target: first.target,
          reason: .couldNotVerifySend,
          failure: .ambiguous
        )
      )
      if keyMatches(first.target, key: state.draftKey) {
        state.target = first.target
      }
      state.contentRevision += 1
      state.contentUpdatedAt = max(state.contentUpdatedAt, date.now())
      for extra in draft.outbound.dropFirst() {
        state.failedSends.append(
          FailedComposerSend(
            messageID: extra.messageID,
            text: extra.text,
            quotes: extra.quotes,
            delivery: extra.delivery,
            target: extra.target,
            reason: .couldNotVerifySend,
            failure: .ambiguous
          )
        )
      }
    }
    if let created = draft.createdSessionID, state.target.isNewSession {
      state.target = .session(id: created)
      state.contentRevision += 1
      state.contentUpdatedAt = max(state.contentUpdatedAt, date.now())
      return .merge(
        .send(.delegate(.restoredCreatedSession(created))),
        persistNow(state: &state)
      )
    }
    if !draft.outbound.isEmpty {
      state.problem = .couldNotVerifySend
      return persistNow(state: &state)
    }
    return .none
  }

  private func keyMatches(_ target: ComposerTarget, key: ComposerDraftKey) -> Bool {
    target.scope == key.scope
  }

  private func scheduleSave(state: inout State) -> Effect<Action> {
    guard !state.isRestoring else { return .none }
    state.saveGeneration += 1
    let generation = state.saveGeneration
    let key = state.draftKey
    let draft = snapshot(state)
    if draft.boundedProblem() == .tooLarge {
      state.problem = .draftTooLarge
      return .none
    }
    let remove = draft.isEmpty
    let clock = clock
    let drafts = drafts
    return .run { send in
      do { try await clock.sleep(.milliseconds(500)) } catch { return }
      let result: ComposerDraftSave
      if remove {
        result = await drafts.remove(key)
      } else {
        result = await drafts.save(draft, key)
      }
      await send(.saveFinished(generation: generation, key: key, result: result))
    }
    .cancellable(id: CancelID.save, cancelInFlight: true)
  }

  private func persistNow(state: inout State) -> Effect<Action> {
    state.saveGeneration += 1
    let generation = state.saveGeneration
    let key = state.draftKey
    let draft = snapshot(state)
    if draft.boundedProblem() == .tooLarge {
      state.problem = .draftTooLarge
      return .none
    }
    if state.pendingDispatch != nil { state.dispatchGeneration = generation }
    let remove = draft.isEmpty
    let drafts = drafts
    return .merge(
      .cancel(id: CancelID.save),
      .run { send in
        let result: ComposerDraftSave
        if remove {
          result = await drafts.remove(key)
        } else {
          result = await drafts.save(draft, key)
        }
        await send(.saveFinished(generation: generation, key: key, result: result))
      }
    )
  }

  private func migrateToCreatedSession(_ sessionID: String, state: inout State) -> Effect<Action> {
    let oldKey = state.draftKey
    guard oldKey.scope != .session(sessionID) else { return .none }
    state.target = .session(id: sessionID)
    state.contentRevision += 1
    state.contentUpdatedAt = max(state.contentUpdatedAt, date.now())
    state.saveGeneration += 1
    let newKey = state.draftKey
    var draft = snapshot(state)
    draft.createdSessionID = sessionID
    let savedDraft = draft
    let drafts = drafts
    return .run { send in
      // The old record gains the created-session link before migration, so a failed destination is
      // still discoverable on relaunch.
      _ = await drafts.save(savedDraft, oldKey)
      let result = await drafts.migrate(savedDraft, oldKey, newKey)
      await send(
        .migrationFinished(
          result: result,
          draft: savedDraft,
          oldKey: oldKey,
          newKey: newKey
        )
      )
    }
  }

  private func switchTarget(_ target: ComposerTarget, state: inout State) -> Effect<Action> {
    guard target != state.target else { return .none }
    state.switchToken += 1
    let token = state.switchToken
    let oldKey = state.draftKey
    let oldDraft = snapshot(state)
    state.parkedDrafts[oldKey] = oldDraft
    state.target = target
    state.draft = ""
    state.quotes = []
    state.failedSends = []
    state.outbound = []
    state.revision = 0
    state.contentRevision = 0
    state.contentUpdatedAt = Date(timeIntervalSince1970: 0)
    state.isSending = false
    state.pendingDispatch = nil
    state.retryDispatch = nil
    state.dispatchGeneration = nil
    state.problem = nil
    let drafts = drafts
    let saveOld = Effect<Action>.run { send in
      let result: ComposerDraftSave
      if oldDraft.isEmpty {
        result = await drafts.remove(oldKey)
      } else {
        result = await drafts.save(oldDraft, oldKey)
      }
      await send(
        .targetSwitchFinished(
          token: token,
          target: target,
          oldKey: oldKey,
          oldDraft: oldDraft,
          result: result
        )
      )
    }
    return .merge(saveOld, loadDraft(state: &state))
  }

  private func resolveOutbound(
    serverID: String,
    target: ComposerTarget,
    messageID: String,
    resolution: ComposerOutboundResolution
  ) -> Effect<Action> {
    let key = ComposerDraftKey(serverID: serverID, scope: target.scope)
    let drafts = drafts
    return .run { _ in
      var outcome = await drafts.load(key)
      if case .missing = outcome, let sessionID = key.scope.sessionID {
        outcome = await drafts.recoverCreated(sessionID, key)
      }
      let loaded: ComposerDraft?
      switch outcome {
      case .found(let draft), .foundFromSource(let draft, _): loaded = draft
      default: loaded = nil
      }
      guard var draft = loaded else { return }
      guard let outbound = draft.outbound.first(where: { $0.messageID == messageID }) else {
        return
      }
      draft.outbound.removeAll { $0.messageID == messageID }
      draft.revision += 1
      switch resolution {
      case .accepted:
        break
      case .failed(let failure), .unverified(let failure):
        draft.failedSends.append(
          FailedComposerSend(
            messageID: outbound.messageID,
            text: outbound.text,
            quotes: outbound.quotes,
            delivery: outbound.delivery,
            target: outbound.target,
            reason: failure == .ambiguous ? .couldNotVerifySend : .couldNotSend,
            failure: failure
          )
        )
      }
      _ = await drafts.save(draft, key)
    }
  }

  private func beginFlushForDismiss(requestID: UUID, state: inout State) -> Effect<Action> {
    state.flushToken += 1
    state.flushRequestID = requestID
    state.saveGeneration += 1
    let token = state.flushToken
    return .merge(
      .cancel(id: CancelID.save),
      flushEffect(requestID: requestID, token: token, key: state.draftKey, draft: snapshot(state))
    )
  }

  private func flushEffect(
    requestID: UUID,
    token: Int,
    key: ComposerDraftKey,
    draft: ComposerDraft
  ) -> Effect<Action> {
    let drafts = drafts
    return .run { send in
      let result: ComposerDraftSave
      if draft.isEmpty {
        result = await drafts.removeIfNotNewer(draft, key)
      } else {
        result = await drafts.saveIfNewer(draft, key)
      }
      await send(.flushSaved(requestID: requestID, token: token, draft: draft, result: result))
    }
  }

  private func flushSaved(
    requestID: UUID,
    token: Int,
    draft: ComposerDraft,
    result: ComposerDraftSave,
    state: inout State
  ) -> Effect<Action> {
    guard token == state.flushToken, requestID == state.flushRequestID else { return .none }
    switch result {
    case .saved:
      let current = snapshot(state)
      guard current.sameContent(as: draft) else {
        state.flushToken += 1
        state.saveGeneration += 1
        let token = state.flushToken
        return .merge(
          .cancel(id: CancelID.save),
          flushEffect(
            requestID: requestID,
            token: token,
            key: state.draftKey,
            draft: current
          )
        )
      }
      state.flushRequestID = nil
      return .send(.delegate(.flushForDismissFinished(requestID: requestID, result: .saved)))
    case .tooLarge, .failure:
      state.flushRequestID = nil
      return .send(.delegate(.flushForDismissFinished(requestID: requestID, result: result)))
    }
  }

  private func snapshot(_ state: State) -> ComposerDraft {
    ComposerDraft(
      text: state.draft,
      quotes: state.quotes,
      projectDirectory: state.target.directory,
      createdSessionID: state.target.isNewSession ? nil : state.target.sessionID,
      failedSends: state.failedSends,
      outbound: state.outbound,
      revision: state.contentRevision,
      updatedAt: state.contentUpdatedAt
    )
  }
}

public enum ComposerOutboundResolution: Equatable, Sendable {
  case accepted
  case failed(ComposerSendFailure)
  case unverified(ComposerSendFailure)
}

extension ComposerDraftLoad {
  var migrationProblem: ComposerProblem? {
    guard case .foundFromSource(_, let migration) = self else { return nil }
    switch migration {
    case .migrated: return nil
    case .destinationFailed: return .couldNotSave
    case .sourceRetained: return .couldNotCleanUpDraft
    }
  }
}

extension ComposerScope {
  public var sessionID: String? {
    if case .session(let id) = self { return id }
    return nil
  }
}
