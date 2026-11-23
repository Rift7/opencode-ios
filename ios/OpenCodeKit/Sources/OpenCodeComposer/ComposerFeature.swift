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

    /// Typing and quote edits bump this, so a send that started earlier cannot clear newer text.
    public var revision: Int
    var restoreToken: Int
    var saveGeneration: Int
    var pendingSend: ComposerSend?

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
      self.revision = 0
      self.restoreToken = 0
      self.saveGeneration = 0
      self.pendingSend = nil
    }

    public var draftKey: ComposerDraftKey {
      ComposerDraftKey(serverID: serverID, scope: target.scope)
    }

    public var canSend: Bool {
      !isSending && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !quotes.isEmpty)
    }

    public var isEmpty: Bool {
      draft.isEmpty && quotes.isEmpty && failedSends.isEmpty
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
    case sendAccepted(messageID: String)
    case sendBlocked(ComposerProblem)
    case sendFailed(messageID: String, failure: ComposerSendFailure)
    /// The POST may have landed and the read-back could not settle it. Keep the optimistic row and
    /// report honestly; a later authoritative read reconciles it.
    case sendUnverified(messageID: String)
    case retryFailed(messageID: String)
    case editFailed(messageID: String)
    case deleteFailed(messageID: String)
    case sessionCreated(String)
    case flush
    case draftLoaded(token: Int, key: ComposerDraftKey, outcome: ComposerDraftLoad)
    case saveDue(generation: Int, key: ComposerDraftKey, draft: ComposerDraft, remove: Bool)
    case saveFinished(generation: Int, key: ComposerDraftKey, result: ComposerDraftSave)
    case delegate(Delegate)
  }

  public enum Delegate: Equatable, Sendable {
    case send(ComposerSend)
    case retry(FailedComposerSend)
    case restoredCreatedSession(String)
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
        return send(delivery: .steer, state: &state)

      case .queueTapped:
        return send(delivery: .queue, state: &state)

      case .sendAccepted:
        state.isSending = false
        state.pendingSend = nil
        state.problem = nil
        if state.target.isNewSession { return .none }
        return scheduleSave(state: &state)

      case .sendUnverified:
        state.isSending = false
        state.pendingSend = nil
        state.problem = .couldNotVerifySend
        haptics.play(.warning)
        return .none

      case .sendBlocked(let problem):
        state.isSending = false
        state.pendingSend = nil
        state.problem = problem
        return .none

      case .sendFailed(let messageID, let failure):
        state.isSending = false
        state.problem = failure == .ambiguous ? .couldNotVerifySend : .couldNotSend
        guard let sent = state.pendingSend else {
          state.pendingSend = nil
          return .none
        }
        state.pendingSend = nil
        haptics.play(.error)
        if state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, state.quotes.isEmpty {
          state.draft = sent.text
          state.quotes = sent.quotes
          state.revision += 1
          state.focusRequest += 1
        } else {
          state.failedSends.append(
            FailedComposerSend(
              messageID: messageID,
              text: sent.text,
              quotes: sent.quotes,
              delivery: sent.delivery,
              reason: state.problem ?? .couldNotSend,
              failure: failure
            )
          )
        }
        return persistNow(state: &state)

      case .retryFailed(let messageID):
        guard !state.isSending,
          let failed = state.failedSends.first(where: { $0.messageID == messageID })
        else { return .none }
        state.isSending = true
        state.problem = nil
        state.failedSends.removeAll { $0.messageID == messageID }
        state.pendingSend = ComposerSend(
          target: state.target,
          messageID: failed.messageID,
          text: failed.text,
          quotes: failed.quotes,
          delivery: failed.delivery,
          revision: state.revision
        )
        haptics.play(.tap)
        return .send(.delegate(.retry(failed)))

      case .editFailed(let messageID):
        guard let failed = state.failedSends.first(where: { $0.messageID == messageID })
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
        let oldKey = state.draftKey
        guard oldKey.scope != .session(sessionID) else { return .none }
        state.target = .session(id: sessionID)
        state.saveGeneration += 1
        let generation = state.saveGeneration
        let newKey = state.draftKey
        var draft = snapshot(state)
        draft.createdSessionID = sessionID
        let savedDraft = draft
        return .run { [drafts] send in
          _ = await drafts.remove(oldKey)
          let result = await drafts.save(savedDraft, newKey)
          await send(.saveFinished(generation: generation, key: newKey, result: result))
        }

      case .flush:
        return persistNow(state: &state)

      case .draftLoaded(let token, let key, let outcome):
        guard token == state.restoreToken else { return .none }
        guard key == state.draftKey else {
          state.isRestoring = false
          return .none
        }
        state.isRestoring = false
        guard state.revision == 0 else { return .none }
        switch outcome {
        case .missing:
          return .none
        case .failure:
          state.problem = .couldNotRestore
          return .none
        case .found(let draft):
          state.draft = draft.text
          state.quotes = draft.quotes
          if let created = draft.createdSessionID, state.target.isNewSession {
            state.target = .session(id: created)
            return .send(.delegate(.restoredCreatedSession(created)))
          }
          return .none
        }

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
        guard generation == state.saveGeneration, key == state.draftKey else { return .none }
        switch result {
        case .saved:
          if state.problem == .couldNotSave || state.problem == .couldNotRestore
            || state.problem == .draftTooLarge
          {
            state.problem = nil
          }
        case .tooLarge:
          state.problem = .draftTooLarge
        case .failure:
          state.problem = .couldNotSave
        }
        return .none

      case .delegate:
        return .none
      }
    }
  }

  private func send(delivery: Delivery, state: inout State) -> Effect<Action> {
    guard state.canSend, let send = makeSend(delivery: delivery, state: state) else { return .none }
    state.isSending = true
    state.pendingSend = send
    state.problem = nil
    state.draft = ""
    state.quotes = []
    state.revision += 1
    haptics.play(.tap)
    let save = persistNow(state: &state)
    return .merge(.send(.delegate(.send(send))), save)
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

  private func loadDraft(state: inout State) -> Effect<Action> {
    state.restoreToken += 1
    state.isRestoring = true
    let token = state.restoreToken
    let key = state.draftKey
    let drafts = drafts
    return .run { send in
      let outcome = await drafts.load(key)
      await send(.draftLoaded(token: token, key: key, outcome: outcome))
    }
    .cancellable(id: CancelID.restore, cancelInFlight: true)
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
    let remove = isEffectivelyEmpty(state)
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
    let remove = isEffectivelyEmpty(state)
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

  private func snapshot(_ state: State) -> ComposerDraft {
    ComposerDraft(
      text: state.draft,
      quotes: state.quotes,
      projectDirectory: state.target.directory,
      createdSessionID: state.target.isNewSession ? nil : state.target.sessionID,
      updatedAt: date.now()
    )
  }

  private func isEffectivelyEmpty(_ state: State) -> Bool {
    state.draft.isEmpty && state.quotes.isEmpty
  }
}
