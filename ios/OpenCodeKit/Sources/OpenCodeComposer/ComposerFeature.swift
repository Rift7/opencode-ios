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
    var restoreToken: Int
    var saveGeneration: Int
    var pendingDispatch: PendingDispatch?
    var dispatchGeneration: Int?
    var switchToken: Int
    var parkedDrafts: [ComposerDraftKey: ComposerDraft]

    struct PendingDispatch: Equatable, Sendable {
      var send: ComposerSend
      var retryFailure: ComposerSendFailure?
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
      self.restoreToken = 0
      self.saveGeneration = 0
      self.pendingDispatch = nil
      self.dispatchGeneration = nil
      self.switchToken = 0
      self.parkedDrafts = [:]
    }

    public var draftKey: ComposerDraftKey {
      ComposerDraftKey(serverID: serverID, scope: target.scope)
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
        updatedAt: Date(timeIntervalSince1970: 0)
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
    case editFailed(messageID: String)
    case deleteFailed(messageID: String)
    case sessionCreated(String)
    case migrationFinished(
      result: ComposerDraftMigration,
      draft: ComposerDraft,
      oldKey: ComposerDraftKey,
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
        return scheduleSave(state: &state)

      case .quoteRemoved(let id):
        guard state.quotes.contains(where: { $0.id == id }) else { return .none }
        state.quotes.removeAll { $0.id == id }
        state.revision += 1
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

      case .sendAccepted:
        state.isSending = false
        state.pendingDispatch = nil
        state.dispatchGeneration = nil
        state.outbound = []
        state.problem = nil
        return scheduleSave(state: &state)

      case .sendUnverified(let messageID):
        state.isSending = false
        state.pendingDispatch = nil
        state.dispatchGeneration = nil
        state.problem = .couldNotVerifySend
        if let outbound = state.outbound.first(where: { $0.messageID == messageID })
          ?? state.outbound.first
        {
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
        }
        haptics.play(.warning)
        return persistNow(state: &state)

      case .sendBlocked(let problem):
        return settleBlocked(problem, state: &state)

      case .sendFailed(let messageID, let failure):
        state.isSending = false
        state.pendingDispatch = nil
        state.dispatchGeneration = nil
        state.problem = failure == .ambiguous ? .couldNotVerifySend : .couldNotSend
        haptics.play(.error)
        guard let outbound = state.outbound.first(where: { $0.messageID == messageID })
          ?? state.outbound.first
        else {
          return persistNow(state: &state)
        }
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
        return persistNow(state: &state)

      case .retryFailed(let messageID):
        guard !state.isSending, state.outbound.isEmpty,
          let failed = state.failedSends.first(where: { $0.messageID == messageID })
        else { return .none }
        state.failedSends.removeAll { $0.messageID == messageID }
        haptics.play(.tap)
        return begin(failed.send, retryFailure: failed.failure, state: &state)

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
        state.problem = nil
        state.focusRequest += 1
        return persistNow(state: &state)

      case .deleteFailed(let messageID):
        state.failedSends.removeAll { $0.messageID == messageID }
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
        return flushForDismiss(requestID: requestID, state: state)

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
    state: inout State
  ) -> Effect<Action> {
    guard !state.isSending, state.outbound.isEmpty else { return .none }
    state.isSending = true
    state.problem = nil
    state.pendingDispatch = State.PendingDispatch(send: send, retryFailure: retryFailure)
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
    return persistNow(state: &state)
  }

  private func dispatchPersisted(messageID: String, state: inout State) -> Effect<Action> {
    guard let pending = state.pendingDispatch, pending.send.messageID == messageID else {
      return .none
    }
    state.pendingDispatch = nil
    state.dispatchGeneration = nil
    state.isSending = true
    if state.revision == pending.send.revision {
      state.draft = ""
      state.quotes = []
      state.revision += 1
    }
    let save = scheduleSave(state: &state)
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
    state.isSending = false
    state.pendingDispatch = nil
    state.dispatchGeneration = nil
    state.problem = problem
    guard let outbound = state.outbound.first else {
      return persistNow(state: &state)
    }
    state.outbound = []
    if state.target.scope != outbound.target.scope {
      return .merge(
        persistNow(state: &state),
        .send(
          .resolveOutbound(
            target: outbound.target,
            messageID: outbound.messageID,
            resolution: .failed(.definite)
          )
        )
      )
    }
    if state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      state.quotes.isEmpty
    {
      state.draft = outbound.text
      state.quotes = outbound.quotes
      state.revision += 1
      state.focusRequest += 1
    } else {
      state.failedSends.append(
        FailedComposerSend(
          messageID: outbound.messageID,
          text: outbound.text,
          quotes: outbound.quotes,
          delivery: outbound.delivery,
          target: outbound.target,
          reason: problem,
          failure: .definite
        )
      )
    }
    return persistNow(state: &state)
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
        state.isSending = false
        state.pendingDispatch = nil
        state.outbound = []
        state.problem = .draftTooLarge
        return .none
      case .failure:
        state.isSending = false
        state.pendingDispatch = nil
        state.outbound = []
        state.problem = .couldNotSave
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
    state.isSending = false
    state.pendingDispatch = nil
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

  private func flushForDismiss(requestID: UUID, state: State) -> Effect<Action> {
    let key = state.draftKey
    let draft = snapshot(state)
    let drafts = drafts
    return .run { send in
      let result: ComposerDraftSave
      if draft.isEmpty {
        result = await drafts.remove(key)
      } else {
        result = await drafts.save(draft, key)
      }
      await send(.delegate(.flushForDismissFinished(requestID: requestID, result: result)))
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
      updatedAt: date.now()
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
