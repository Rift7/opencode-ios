import ComposableArchitecture
import Foundation
import OpenCodeComposer
import OpenCodeCore
import OpenCodeDrawer
import OpenCodeMedia
import OpenCodeServer
import OpenCodeSession

// MARK: - Shared app-shell values

/// Why a connection could not be established or maintained. The value carries facts only; the view
/// chooses localized copy.
public enum ConnectionFailure: Equatable, Sendable {
  case invalidAddress
  case unreachable
  case offline
  case timedOut
  case credentialsRejected
  case incompatibleAPI(feature: String)
  case malformed(feature: String)
  case serverStatus(Int)
  case pairingExpired
  case pairingUnsupported
  case streamEnded
  case streamOverflow
  case unsupported
  case unknown

  public static func from(_ error: OpenCodeClientError, isOffline: Bool = false) -> ConnectionFailure {
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
    case .invalidURL:
      return .invalidAddress
    case .unsupported:
      return .unsupported
    case .undecodable(let feature):
      return .malformed(feature: feature)
    case .incompatibleAPI(let feature):
      return .incompatibleAPI(feature: feature)
    case .unreachable:
      return isOffline ? .offline : .unreachable
    case .streamEnded:
      return .streamEnded
    case .streamServerFailure:
      return .streamEnded
    case .streamOversizedFrame:
      return .streamEnded
    case .streamOverflow:
      return .streamOverflow
    case .pairingExpired:
      return .pairingExpired
    case .pairingUnsupported:
      return .pairingUnsupported
    }
  }
}

/// Why pairing text did not become a connection. Parsing stays free of transport.
public enum PairingProblem: Equatable, Sendable {
  case emptyClipboard
  case notPairingText
  case invalidCode
  case unusableAddress(address: String, reason: PairingAddressProblem)
  case loopback
  case expired
  case unsupported
  case connection(ConnectionFailure)

  public static func from(_ error: OpenCodeClientError, isOffline: Bool = false) -> PairingProblem {
    switch error.failure {
    case .pairingExpired:
      return .expired
    case .pairingUnsupported:
      return .unsupported
    default:
      return .connection(.from(error, isOffline: isOffline))
    }
  }
}

/// A pairing link waiting for explicit confirmation. An opened link must never spend its one-time
/// code before the person taps Pair.
public struct PairingConfirmation: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let link: PairingLink
  public let replacedServerNames: [String]

  public init(id: UUID, link: PairingLink, replacedServerNames: [String] = []) {
    self.id = id
    self.link = link
    self.replacedServerNames = replacedServerNames
  }

  /// Distinct display hosts in the order redemption will try them.
  public var hosts: [String] {
    var seen = Set<String>()
    return link.redeemOrigins.compactMap { origin in
      guard let host = ServerOrigin(address: origin)?.host else { return nil }
      let key = host.lowercased()
      guard seen.insert(key).inserted else { return nil }
      return host
    }
  }
}

public struct PairingAttempt: Equatable, Sendable {
  public let id: Int
  public let link: PairingLink

  public init(id: Int, link: PairingLink) {
    self.id = id
    self.link = link
  }
}

public enum ServerFormProblem: Equatable, Sendable {
  case emptyAddress
  case invalidAddress(ServerOrigin.Problem)
}

/// The manual-entry form. Address validation runs on Connect; other fields only trim on connect.
public struct ServerForm: Equatable, Sendable {
  public var name: String
  public var address: String
  public var username: String
  public var password: String
  public var isEditingSaved: Bool
  public var problem: ServerFormProblem?

  public init(
    name: String = "",
    address: String = "",
    username: String = "opencode",
    password: String = "",
    isEditingSaved: Bool = false,
    problem: ServerFormProblem? = nil
  ) {
    self.name = name
    self.address = address
    self.username = username
    self.password = password
    self.isEditingSaved = isEditingSaved
    self.problem = problem
  }

  public var server: OpenCodeServer? {
    let origin: ServerOrigin
    switch ServerOrigin.parse(AppFeature.withDefaultScheme(address.trimmingCharacters(in: .whitespacesAndNewlines))) {
    case .success(let value): origin = value
    case .failure: return nil
    }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
    return OpenCodeServer(
      url: origin.address,
      username: trimmedUser.isEmpty ? "opencode" : trimmedUser,
      password: password,
      name: trimmedName.isEmpty ? nil : trimmedName
    )
  }
}

public enum AppNotice: Equatable, Sendable {
  case couldNotSaveServer(StorageFailure)
  case couldNotReadSavedServers
  case couldNotReadCache
  case couldNotReplaceSavedData(StorageFailure)
  case couldNotSaveDraft
  case draftKept
}

/// The session a Done tap is trying to close. Late completion is accepted only for this identity.
public struct PendingSessionDismissal: Equatable, Sendable {
  public var requestID: UUID
  public var serverID: String
  public var sessionID: String

  public init(requestID: UUID, serverID: String, sessionID: String) {
    self.requestID = requestID
    self.serverID = serverID
    self.sessionID = sessionID
  }
}

/// A departing composer draft whose save is still owned by the app after its session closed.
public struct DraftTransfer: Equatable, Sendable, Identifiable {
  public var id: UUID
  public var key: ComposerDraftKey
  public var draft: ComposerDraft
  public var failure: StorageFailure?

  public init(
    id: UUID,
    key: ComposerDraftKey,
    draft: ComposerDraft,
    failure: StorageFailure? = nil
  ) {
    self.id = id
    self.key = key
    self.draft = draft
    self.failure = failure
  }
}

public enum AppRestore: Equatable, Sendable {
  case idle
  case ready
  case storageUnavailable(StorageFailure)
  case corruptSavedServers
}

/// Whether the saved server list was actually read. Only `.read` permits persistence; an unreadable
/// list is preserved until the person explicitly replaces it.
public enum SavedDataState: Equatable, Sendable {
  case notLoaded
  case read
  case unreadable(SavedDataProblem)

  public var isReadable: Bool { self == .read }
  public var isUnreadable: Bool {
    if case .unreadable = self { return true }
    return false
  }
}

public enum SavedDataProblem: Equatable, Sendable {
  case storage(StorageFailure)
  case corrupt
}

/// A read of the launch keys. Missing, corrupt and unavailable are separate answers; only an
/// explicit destructive action may remove saved credentials.
public enum AppRestoreResult: Equatable, Sendable {
  case missing
  case restored(
    server: OpenCodeServer,
    servers: [OpenCodeServer],
    cache: CachedServerSummary?,
    notice: AppNotice?
  )
  case corrupt
  case storageUnavailable(StorageFailure)

  public static func read(_ store: SharedStore) -> AppRestoreResult {
    let saved = store.read(ServerSharedKeys.savedServer)
    let list = store.read(ServerSharedKeys.savedServers)
    let cache = store.read(ServerSharedKeys.cachedSummaries)

    if case .failure(let failure) = saved { return .storageUnavailable(failure) }
    if case .failure(let failure) = list { return .storageUnavailable(failure) }

    let savedServer: OpenCodeServer? = {
      if case .value(let value) = saved { return value }
      return nil
    }()
    let savedServers: [OpenCodeServer] = {
      if case .value(let value) = list { return value }
      return []
    }()

    let server = savedServer ?? savedServers.first
    guard let server else {
      if case .undecodable = saved { return .corrupt }
      if case .undecodable = list { return .corrupt }
      return .missing
    }

    var notice: AppNotice?
    if case .undecodable = list { notice = .couldNotReadSavedServers }
    if case .undecodable = saved { notice = .couldNotReadSavedServers }

    var summary: CachedServerSummary?
    switch cache {
    case .value(let summaries):
      summary = summaries[server.persistenceID]
    case .undecodable:
      notice = notice ?? .couldNotReadCache
    case .failure:
      notice = notice ?? .couldNotReadCache
    case .missing:
      break
    }

    return .restored(server: server, servers: savedServers, cache: summary, notice: notice)
  }
}

/// Saves a verified server at the top of the list without dropping local settings.
public enum SavedServers {
  public static func remembering(
    _ server: OpenCodeServer,
    among saved: [OpenCodeServer]
  ) -> [OpenCodeServer] {
    let entry = server.keepingLocalSettings(saved: saved)
    return [entry] + saved.filter { !entry.supersedes($0) }
  }
}

// MARK: - Connection child

/// One connection attempt's lifetime. The parent identifies this state by `id`; replacing it or
/// clearing it cancels the health race, REST refresh and event stream.
@Reducer
public struct ConnectionFeature {
  @ObservableState
  public struct State: Equatable, Identifiable, Sendable {
    public enum Phase: Equatable, Sendable {
      case connecting
      case loading
      case connected
      case reconnecting
      case failed
    }

    public let id: Int
    public var server: OpenCodeServer
    public var phase: Phase
    public var info: ServerInfo?
    public var projects: [ServerProject]
    public var failure: ConnectionFailure?
    public var isOffline: Bool
    public var isInForeground: Bool
    /// A UI-test scenario is pinned: no effect may reach the network.
    public var isPinned: Bool

    /// One gate for every start: foreground and a known non-offline path.
    public var canAttempt: Bool { isInForeground && !isOffline }

    var attempt = 0
    var streamID = 0
    var hasBeenConnected = false

    public init(
      id: Int,
      server: OpenCodeServer,
      phase: Phase = .connecting,
      info: ServerInfo? = nil,
      projects: [ServerProject] = [],
      failure: ConnectionFailure? = nil,
      isOffline: Bool = false,
      isInForeground: Bool = true,
      isPinned: Bool = false
    ) {
      self.id = id
      self.server = server
      self.phase = phase
      self.info = info
      self.projects = projects
      self.failure = failure
      self.isOffline = isOffline
      self.isInForeground = isInForeground
      self.isPinned = isPinned
      self.attempt = id * 1_000
    }

    /// Effect bookkeeping is deliberately outside equality: a test asserts the visible connection,
    /// and the generation counters only guard stale callbacks.
    public static func == (lhs: State, rhs: State) -> Bool {
      lhs.id == rhs.id
        && lhs.server == rhs.server
        && lhs.phase == rhs.phase
        && lhs.info == rhs.info
        && lhs.projects == rhs.projects
        && lhs.failure == rhs.failure
        && lhs.isOffline == rhs.isOffline
        && lhs.isInForeground == rhs.isInForeground
        && lhs.isPinned == rhs.isPinned
    }
  }

  /// Identity for one attempt's stream. A retry, replacement, backgrounding, path loss or
  /// disconnect changes the token, so delayed callbacks from the old work cannot touch state.
  public struct Token: Equatable, Sendable {
    public let attempt: Int
    public let stream: Int

    public init(attempt: Int, stream: Int) {
      self.attempt = attempt
      self.stream = stream
    }
  }

  public enum Action: Equatable, Sendable {
    case task
    case retryTapped
    case scenePhaseChanged(isActive: Bool)
    case networkPathChanged(NetworkPath)
    case healthFinished(attempt: Int, result: Result<ServerLinkProbe, OpenCodeClientError>)
    case refreshFinished(attempt: Int, result: Result<[ServerProject], OpenCodeClientError>)
    case streamResynchronized(token: Token, result: Result<[ServerProject], OpenCodeClientError>)
    case streamPhase(token: Token, phase: EventStreamPhase)
    case streamEvent(token: Token, event: ServerEvent)
    case delegate(Delegate)
  }

  public enum Delegate: Equatable, Sendable {
    case verified(OpenCodeServer, ServerInfo)
    case projects(OpenCodeServer, [ServerProject], ServerInfo?)
    /// REST was re-read after a handshake, so Home can replace any read that started earlier.
    case available(OpenCodeServer)
    /// The socket dropped and the connection is reconnecting; Home must stop claiming live status.
    case unavailable(OpenCodeServer)
    /// A reconnect or overflow completed and REST was re-read before the next socket.
    case resynchronized(OpenCodeServer)
    /// A session-scoped event the stream owner forwards to Home; the stream stays single-owner.
    case sessionEvent(OpenCodeServer, ServerEvent)
    case failed(ConnectionFailure)
  }

  enum CancelID: Hashable {
    case health
    case refresh
    case stream
  }

  @Dependency(\.openCodeClient) private var client
  @Dependency(\.clock) private var clock

  public init() {}

  public var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task, .retryTapped:
        guard !state.isPinned else { return .none }
        return startIfEligible(&state)

      case .scenePhaseChanged(let isActive):
        state.isInForeground = isActive
        guard !state.isPinned else { return .none }
        if !isActive {
          if state.phase == .failed { return stopWork(&state) }
          if state.hasBeenConnected { state.phase = .reconnecting }
          return stopWork(&state)
        }
        if state.phase == .failed && state.failure != .offline { return .none }
        return startIfEligible(&state)

      case .networkPathChanged(let path):
        let wasOffline = state.isOffline
        state.isOffline = path.isOffline
        guard !state.isPinned else { return .none }
        if path.isOffline {
          if state.phase != .failed { state.phase = .reconnecting }
          return stopWork(&state)
        }
        if wasOffline, state.phase != .failed || state.failure == .offline {
          return startIfEligible(&state)
        }
        return .none

      case .healthFinished(let attempt, let result):
        guard attempt == state.attempt else { return .none }
        switch result {
        case .success(let probe):
          guard state.canAttempt else {
            state.server = probe.server
            state.info = probe.info
            state.phase = .reconnecting
            return stopWork(&state)
          }
          state.server = probe.server
          state.info = probe.info
          state.failure = nil
          state.phase = .loading
          let token = nextStreamToken(&state)
          return .merge(
            .send(.delegate(.verified(probe.server, probe.info))),
            streamEffect(server: probe.server, token: token)
          )
        case .failure(let error):
          return fail(&state, .from(error, isOffline: state.isOffline))
        }

      case .refreshFinished(let attempt, let result):
        guard attempt == state.attempt else { return .none }
        switch result {
        case .success(let projects):
          state.projects = projects
          state.phase = .connected
          state.failure = nil
          state.hasBeenConnected = true
          AppLog(category: .app).event(
            .connectionReady,
            [LogField("projects", .count(projects.count))]
          )
          return .concatenate(
            .send(.delegate(.projects(state.server, projects, state.info))),
            .send(.delegate(.available(state.server)))
          )
        case .failure(let error):
                return .merge(.cancel(id: CancelID.stream), fail(&state, .from(error, isOffline: state.isOffline)))
        }

      case .streamResynchronized(let token, let result):
        guard token == currentToken(state), !state.isPinned else { return .none }
        if case .success(let projects) = result {
          state.projects = projects
          return .concatenate(
            .send(.delegate(.projects(state.server, projects, state.info))),
            .send(.delegate(.resynchronized(state.server)))
          )
        }
        return .none

      case .streamPhase(let token, let phase):
        guard token == currentToken(state), !state.isPinned else { return .none }
        switch phase {
        case .connected:
          guard state.phase != .failed else { return .none }
          return refreshEffect(attempt: state.attempt, server: state.server)
        case .disconnected(let error):
          if let error, error.statusCode == 401 {
            return fail(&state, .credentialsRejected)
          }
          if state.phase != .failed {
            state.phase = .reconnecting
            state.failure = nil
            return .send(.delegate(.unavailable(state.server)))
          }
          return .none
        case .resynchronizing:
          if state.phase != .failed {
            state.phase = .reconnecting
            return .send(.delegate(.unavailable(state.server)))
          }
          return .none
        case .ended(let error):
          guard state.phase != .failed else { return .none }
          let failure = error.map { ConnectionFailure.from($0, isOffline: state.isOffline) } ?? .streamEnded
          return fail(&state, failure)
        }

      case .streamEvent(let token, let event):
        guard token == currentToken(state), !state.isPinned else { return .none }
        switch event {
        case .projectUpdated(let project):
          if let index = state.projects.firstIndex(where: { $0.id == project.id }) {
            state.projects[index] = project
          } else {
            state.projects.append(project)
          }
          return .send(.delegate(.projects(state.server, state.projects, state.info)))
        case .connected, .modelsChanged, .agentsChanged:
          return .none
        default:
          // The shell owns the only stream. Session decides which events it owns; forwarding
          // everything else here keeps queues, durable boundaries, reverts, shells and jobs
          // from being dropped at the connection boundary.
          return .send(.delegate(.sessionEvent(state.server, event)))
        }

      case .delegate:
        return .none
      }
    }
  }

  private func startIfEligible(_ state: inout State) -> Effect<Action> {
    guard state.canAttempt else { return stopWork(&state, phase: .reconnecting) }
    return startConnecting(&state)
  }

  private func currentToken(_ state: State) -> Token {
    Token(attempt: state.attempt, stream: state.streamID)
  }

  private func nextStreamToken(_ state: inout State) -> Token {
    state.streamID += 1
    return currentToken(state)
  }

  /// Invalidates every callback from the work being cancelled. Called for backgrounding, path
  /// loss, retry, replacement and failure, so a delayed answer cannot touch the new attempt.
  private func stopWork(
    _ state: inout State,
    phase: State.Phase? = nil
  ) -> Effect<Action> {
    state.attempt += 1
    state.streamID += 1
    if let phase { state.phase = phase }
    return .merge(
      .cancel(id: CancelID.health),
      .cancel(id: CancelID.refresh),
      .cancel(id: CancelID.stream)
    )
  }

  private func startConnecting(_ state: inout State) -> Effect<Action> {
    state.attempt += 1
    state.streamID += 1
    let attempt = state.attempt
    state.phase = state.hasBeenConnected ? .reconnecting : .connecting
    state.failure = nil
    let server = state.server
    let client = client
    let clock = clock
    AppLog(category: .app).event(
      .connectionAttempt,
      [LogField("candidates", .count(server.candidateURLs.count))]
    )

    let health = Effect<Action>.run { send in
      do {
        let probe = try await ServerLink.probe(server, health: client.health, clock: clock)
        await send(.healthFinished(attempt: attempt, result: .success(probe)))
      } catch let error as OpenCodeClientError {
        await send(.healthFinished(attempt: attempt, result: .failure(error)))
      } catch is CancellationError {
        return
      } catch {
        await send(.healthFinished(attempt: attempt, result: .failure(OpenCodeClientError(.unreachable))))
      }
    }
    .cancellable(id: CancelID.health, cancelInFlight: true)

    return .merge(
      .cancel(id: CancelID.refresh),
      .cancel(id: CancelID.stream),
      health
    )
  }

  private func refreshEffect(attempt: Int, server: OpenCodeServer) -> Effect<Action> {
    let client = client
    return .run { send in
      do {
        let projects = try await client.projects(server)
        await send(.refreshFinished(attempt: attempt, result: .success(projects)))
      } catch let error as OpenCodeClientError {
        await send(.refreshFinished(attempt: attempt, result: .failure(error)))
      } catch is CancellationError {
        return
      } catch {
        await send(.refreshFinished(attempt: attempt, result: .failure(OpenCodeClientError(.unreachable))))
      }
    }
    .cancellable(id: CancelID.refresh, cancelInFlight: true)
  }

  private func streamEffect(server: OpenCodeServer, token: Token) -> Effect<Action> {
    let client = client
    return .run { send in
      let stream = client.events(server) { phase in
        if case .resynchronizing = phase {
          await send(.streamPhase(token: token, phase: phase))
          do {
            let projects = try await client.projects(server)
            await send(.streamResynchronized(token: token, result: .success(projects)))
          } catch let error as OpenCodeClientError {
            await send(.streamResynchronized(token: token, result: .failure(error)))
          } catch is CancellationError {
            return
          } catch {
            await send(.streamResynchronized(token: token, result: .failure(OpenCodeClientError(.unreachable))))
          }
        } else {
          await send(.streamPhase(token: token, phase: phase))
        }
      }
      do {
        for try await event in stream {
          await send(.streamEvent(token: token, event: event))
        }
        await send(.streamPhase(token: token, phase: .ended(nil)))
      } catch is CancellationError {
        return
      } catch let error as OpenCodeClientError {
        await send(.streamPhase(token: token, phase: .ended(error)))
      } catch {
        await send(.streamPhase(token: token, phase: .ended(OpenCodeClientError(.unreachable))))
      }
    }
    .cancellable(id: CancelID.stream, cancelInFlight: true)
  }

  private func fail(_ state: inout State, _ failure: ConnectionFailure) -> Effect<Action> {
    state.attempt += 1
    state.streamID += 1
    state.phase = .failed
    state.failure = failure

    state.phase = .failed
    state.failure = failure
    AppLog(category: .app).event(
      .connectionFailed,
      [
        LogField("offline", .flag(failure == .offline)),
        LogField("auth", .flag(failure == .credentialsRejected)),
      ]
    )
    return .merge(
      .cancel(id: CancelID.health),
      .cancel(id: CancelID.refresh),
      .cancel(id: CancelID.stream),
      .send(.delegate(.failed(failure)))
    )
  }
}

// MARK: - App parent

@Reducer
public struct AppFeature {
  @ObservableState
  public struct State: Equatable, Sendable {
    public var restore: AppRestore
    public var connection: ConnectionFeature.State?
    public var home: HomeFeature.State?
    public var session: SessionFeature.State?
    public var sessionDestination: SessionSelection?
    public var savedServer: OpenCodeServer?
    public var savedServers: [OpenCodeServer]
    public var form: ServerForm?
    public var pendingPairing: PairingConfirmation?
    public var pairingAttempt: PairingAttempt?
    public var pairingProblem: PairingProblem?
    public var pasteProblem: PairingProblem?
    public var notice: AppNotice?
    public var isInForeground: Bool
    public var networkPath: NetworkPath
    public var isPinnedForUITest: Bool
    public var savedData: SavedDataState
    public var showsReplaceSavedDataConfirmation: Bool
    public var pendingDismissal: PendingSessionDismissal?
    public var pendingDraftTransfers: [UUID: DraftTransfer]
    public var retainedDraftTransfers: [ComposerDraftKey: DraftTransfer]

    var didStart = false
    var pendingSave: OpenCodeServer?
    var nextConnectionID = 1
    var nextPairingAttempt = 1
    var nextSessionID = 1

    public init(
      restore: AppRestore = .idle,
      connection: ConnectionFeature.State? = nil,
      home: HomeFeature.State? = nil,
      session: SessionFeature.State? = nil,
      sessionDestination: SessionSelection? = nil,
      savedServer: OpenCodeServer? = nil,
      savedServers: [OpenCodeServer] = [],
      form: ServerForm? = nil,
      pendingPairing: PairingConfirmation? = nil,
      pairingAttempt: PairingAttempt? = nil,
      pairingProblem: PairingProblem? = nil,
      pasteProblem: PairingProblem? = nil,
      notice: AppNotice? = nil,
      isInForeground: Bool = true,
      networkPath: NetworkPath = .online,
      isPinnedForUITest: Bool = false,
      savedData: SavedDataState = .notLoaded,
      showsReplaceSavedDataConfirmation: Bool = false,
      pendingDismissal: PendingSessionDismissal? = nil,
      pendingDraftTransfers: [UUID: DraftTransfer] = [:],
      retainedDraftTransfers: [ComposerDraftKey: DraftTransfer] = [:]
    ) {
      self.restore = restore
      self.connection = connection
      self.home = home
      self.session = session
      self.sessionDestination = sessionDestination
      self.savedServer = savedServer
      self.savedServers = savedServers
      self.form = form
      self.pendingPairing = pendingPairing
      self.pairingAttempt = pairingAttempt
      self.pairingProblem = pairingProblem
      self.pasteProblem = pasteProblem
      self.notice = notice
      self.isInForeground = isInForeground
      self.networkPath = networkPath
      self.isPinnedForUITest = isPinnedForUITest
      self.savedData = savedData
      self.showsReplaceSavedDataConfirmation = showsReplaceSavedDataConfirmation
      self.pendingDismissal = pendingDismissal
      self.pendingDraftTransfers = pendingDraftTransfers
      self.retainedDraftTransfers = retainedDraftTransfers
    }

    public static func == (lhs: State, rhs: State) -> Bool {
      lhs.restore == rhs.restore
        && lhs.connection == rhs.connection
        && lhs.home == rhs.home
        && lhs.session == rhs.session
        && lhs.sessionDestination == rhs.sessionDestination
        && lhs.savedServer == rhs.savedServer
        && lhs.savedServers == rhs.savedServers
        && lhs.form == rhs.form
        && lhs.pendingPairing == rhs.pendingPairing
        && lhs.pairingAttempt == rhs.pairingAttempt
        && lhs.pairingProblem == rhs.pairingProblem
        && lhs.pasteProblem == rhs.pasteProblem
        && lhs.notice == rhs.notice
        && lhs.isInForeground == rhs.isInForeground
        && lhs.networkPath == rhs.networkPath
        && lhs.isPinnedForUITest == rhs.isPinnedForUITest
        && lhs.savedData == rhs.savedData
        && lhs.showsReplaceSavedDataConfirmation == rhs.showsReplaceSavedDataConfirmation
        && lhs.pendingDismissal == rhs.pendingDismissal
        && lhs.pendingDraftTransfers == rhs.pendingDraftTransfers
        && lhs.retainedDraftTransfers == rhs.retainedDraftTransfers
    }
  }

  public enum Action: Equatable, Sendable {
    case task
    case restored(AppRestoreResult)
    case memoryWarning
    case scenePhaseChanged(isActive: Bool)
    case networkPathChanged(NetworkPath)
    case restoreRetried
    case forgetSavedServersTapped
    case manualEntryTapped
    case formDismissed
    case formNameChanged(String)
    case formAddressChanged(String)
    case formUsernameChanged(String)
    case formPasswordChanged(String)
    case formSubmitted
    case savedServerTapped(OpenCodeServer)
    case pastePairingTapped
    case openURL(String)
    case pairingConfirmed(UUID)
    case pairingCancelled
    case pairingProblemDismissed
    case pairingFinished(attempt: Int, result: Result<OpenCodeServer, OpenCodeClientError>)
    case disconnectTapped
    case sessionDestinationDismissed
    case draftTransferFinished(
      id: UUID,
      key: ComposerDraftKey,
      draft: ComposerDraft,
      result: ComposerDraftSave
    )
    case retryRetainedDrafts
    case noticeDismissed
    case persisted(saved: StorageWrite, list: StorageWrite)
    case replaceSavedDataTapped
    case replaceSavedDataCancelled
    case replaceSavedDataConfirmed
    case replaceSavedDataFinished(
      deleteSaved: StorageWrite,
      deleteList: StorageWrite,
      save: StorageWrite,
      list: StorageWrite
    )
    case connection(ConnectionFeature.Action)
    case home(HomeFeature.Action)
    case session(SessionFeature.Action)
  }

  enum CancelID: Hashable {
    case restore
    case path
    case pairing
  }

  @Dependency(\.sharedStore) private var store
  @Dependency(\.openCodeClient) private var client
  @Dependency(\.networkPath) private var networkPath
  @Dependency(\.pasteboard) private var pasteboard
  @Dependency(\.uuidClient) private var uuid
  @Dependency(\.composerDrafts) private var composerDrafts
  @Dependency(\.mediaReferences) private var mediaReferences
  @Dependency(\.mediaImages) private var mediaImages
  @Dependency(\.mediaScratch) private var mediaScratch
  @Dependency(\.mediaFiles) private var mediaFiles

  public init() {}

  public var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        guard !state.didStart else { return .none }
        state.didStart = true
        if state.isPinnedForUITest { return .none }
        let scratch = mediaScratch
        let files = mediaFiles
        let cleanup = Effect<Action>.run { _ in
          await scratch.store.cleanup()
          await files.store.cleanupTemporaryArtifacts()
        }
        return .merge(restoreEffect(), pathEffect(), retryRetainedEffect(state: state), cleanup)

      case .memoryWarning:
        let references = mediaReferences
        let images = mediaImages
        return .run { _ in
          await images.purged()
          await references.trim()
        }

      case .restored(let result):
        switch result {
        case .missing:
          state.restore = .ready
          state.savedData = .read
          AppLog(category: .app).event(.launchStarted, [LogField("restored", .flag(false))])
          if let pending = state.pendingSave {
            let servers = SavedServers.remembering(pending, among: state.savedServers)
            state.savedServer = servers.first ?? pending
            state.savedServers = servers
            state.pendingSave = nil
            return persistEffect(server: pending, servers: servers)
          }
          return .none

        case .storageUnavailable(let failure):
          state.restore = .storageUnavailable(failure)
          state.savedData = .unreadable(.storage(failure))
          AppLog(category: .app).event(
            .launchFailed,
            [LogField("storage", .flag(true))]
          )
          return .none

        case .corrupt:
          state.restore = .corruptSavedServers
          state.savedData = .unreadable(.corrupt)
          AppLog(category: .app).event(
            .launchFailed,
            [LogField("corrupt", .flag(true))]
          )
          return .none

        case .restored(let server, let servers, let cache, let notice):
          let corruptCredentialData = notice == .couldNotReadSavedServers
          state.restore = .ready
          state.savedData = corruptCredentialData ? .unreadable(.corrupt) : .read
          state.notice = notice
          AppLog(category: .app).event(
            .launchStarted,
            [
              LogField("restored", .flag(true)),
              LogField("cached", .flag(cache != nil)),
              LogField("servers", .count(servers.count)),
            ]
          )

          var persistence: Effect<Action> = .none
          if let pending = state.pendingSave {
            let reconciled = SavedServers.remembering(pending, among: servers)
            state.savedServer = reconciled.first ?? pending
            state.savedServers = reconciled
            if corruptCredentialData {
              state.pendingSave = pending
            } else {
              state.pendingSave = nil
              persistence = persistEffect(server: pending, servers: reconciled)
            }
          } else {
            state.savedServer = server
            state.savedServers = servers
          }

          guard state.connection == nil else { return persistence }
          let id = state.nextConnectionID
          state.nextConnectionID += 1
          state.connection = ConnectionFeature.State(
            id: id,
            server: server,
            phase: .connecting,
            projects: cache?.projects ?? [],
            isOffline: state.networkPath.isOffline,
            isInForeground: state.isInForeground,
            isPinned: state.isPinnedForUITest
          )
          return .merge(persistence, .send(.connection(.task)))
        }

      case .scenePhaseChanged(let isActive):
        state.isInForeground = isActive
        guard state.connection != nil else { return .none }
        let live = homeIsLive(state)
        var effects: [Effect<Action>] = [
          .send(.connection(.scenePhaseChanged(isActive: isActive)))
        ]
        if isActive { effects.append(retryRetainedEffect(state: state)) }
        if state.home != nil { effects.append(.send(.home(.connectionChanged(isConnected: live)))) }
        if state.session != nil {
          effects.append(.send(.session(.connectionChanged(isConnected: live))))
          if !isActive { effects.append(.send(.session(.composer(.flush)))) }
        }
        return .merge(effects)

      case .networkPathChanged(let path):
        state.networkPath = path
        guard state.connection != nil else { return .none }
        let live = homeIsLive(state)
        var effects: [Effect<Action>] = [
          .send(.connection(.networkPathChanged(path)))
        ]
        if state.home != nil { effects.append(.send(.home(.connectionChanged(isConnected: live)))) }
        if state.session != nil { effects.append(.send(.session(.connectionChanged(isConnected: live)))) }
        return .merge(effects)

      case .restoreRetried:
        state.restore = .idle
        return restoreEffect()

      case .forgetSavedServersTapped:
        let saved = store.delete(ServerSharedKeys.savedServer)
        let list = store.delete(ServerSharedKeys.savedServers)
        if case .failure(let failure) = saved { return .send(.restored(.storageUnavailable(failure))) }
        if case .failure(let failure) = list { return .send(.restored(.storageUnavailable(failure))) }
        state.savedServer = nil
        state.savedServers = []
        state.savedData = .read
        state.pendingSave = nil
        state.restore = .ready
        state.connection = nil
        state.home = nil
        state.session = nil
        state.sessionDestination = nil
        state.notice = nil
        return .none

      case .replaceSavedDataTapped:
        state.showsReplaceSavedDataConfirmation = true
        return .none

      case .replaceSavedDataCancelled:
        state.showsReplaceSavedDataConfirmation = false
        return .none

      case .replaceSavedDataConfirmed:
        state.showsReplaceSavedDataConfirmation = false
        guard let server = state.savedServers.first ?? state.savedServer else {
          return .none
        }
        let servers = state.savedServers.isEmpty ? [server] : state.savedServers
        let store = store
        return .run { send in
          let deleteSaved = store.delete(ServerSharedKeys.savedServer)
          let deleteList = store.delete(ServerSharedKeys.savedServers)
          var save: StorageWrite = .failure(.unavailable)
          var list: StorageWrite = .failure(.unavailable)
          if case .success = deleteSaved, case .success = deleteList {
            save = store.write(server, for: ServerSharedKeys.savedServer)
            list = store.write(servers, for: ServerSharedKeys.savedServers)
          }
          await send(
            .replaceSavedDataFinished(
              deleteSaved: deleteSaved,
              deleteList: deleteList,
              save: save,
              list: list
            )
          )
        }

      case .replaceSavedDataFinished(let deleteSaved, let deleteList, let save, let list):
        if case .failure(let failure) = deleteSaved {
          state.notice = .couldNotReplaceSavedData(failure)
          return .none
        }
        if case .failure(let failure) = deleteList {
          state.notice = .couldNotReplaceSavedData(failure)
          return .none
        }
        if case .failure(let failure) = save {
          state.notice = .couldNotReplaceSavedData(failure)
          return .none
        }
        if case .failure(let failure) = list {
          state.notice = .couldNotReplaceSavedData(failure)
          return .none
        }
        state.savedData = .read
        state.pendingSave = nil
        state.restore = .ready
        state.notice = nil
        return .none

      case .manualEntryTapped:
        state.form = ServerForm()
        state.pairingProblem = nil
        state.pasteProblem = nil
        return .none

      case .formDismissed:
        state.form = nil
        return .none

      case .formNameChanged(let value):
        state.form?.name = value
        state.form?.problem = nil
        return .none

      case .formAddressChanged(let value):
        state.form?.address = value
        state.form?.problem = nil
        return .none

      case .formUsernameChanged(let value):
        state.form?.username = value
        return .none

      case .formPasswordChanged(let value):
        state.form?.password = value
        return .none

      case .formSubmitted:
        guard var form = state.form else { return .none }
        let text = form.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
          form.problem = .emptyAddress
          state.form = form
          return .none
        }
        if PairingLink.decodeCopied(text) != nil || PairingLink.isPairingEndpoint(text) {
          state.form = nil
          return handlePairingText(text, requiresConfirmation: false, state: &state)
        }
        let address = Self.withDefaultScheme(text)
        switch ServerOrigin.parse(address) {
        case .failure(let problem):
          form.problem = .invalidAddress(problem)
          state.form = form
          return .none
        case .success:
          guard let server = form.server else {
            form.problem = .invalidAddress(.notAWebAddress)
            state.form = form
            return .none
          }
          state.form = nil
          return connect(to: server, state: &state)
        }

      case .savedServerTapped(let server):
        state.form = nil
        state.pasteProblem = nil
        state.pairingProblem = nil
        return connect(to: server, state: &state)

      case .pastePairingTapped:
        guard let text = pasteboard.string(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          state.pasteProblem = .emptyClipboard
          return .none
        }
        return handlePairingText(text, requiresConfirmation: false, state: &state)

      case .openURL(let text):
        return handlePairingText(text, requiresConfirmation: true, state: &state)

      case .pairingConfirmed(let id):
        guard let pending = state.pendingPairing, pending.id == id else { return .none }
        state.pendingPairing = nil
        return redeem(pending.link, state: &state)

      case .pairingCancelled:
        state.pendingPairing = nil
        return .none

      case .pairingProblemDismissed:
        state.pairingProblem = nil
        state.pasteProblem = nil
        return .none

      case .pairingFinished(let attempt, let result):
        guard state.pairingAttempt?.id == attempt else { return .none }
        state.pairingAttempt = nil
        switch result {
        case .success(let server):
          state.pairingProblem = nil
          return connect(to: server, state: &state)
        case .failure(let error):
          state.pairingProblem = .from(error, isOffline: state.networkPath.isOffline)
          return .none
        }

      case .disconnectTapped:
        let transfer = transferDraft(from: state.session, state: &state)
        state.connection = nil
        state.home = nil
        state.session = nil
        state.sessionDestination = nil
        state.pairingAttempt = nil
        state.pendingPairing = nil
        state.pendingSave = nil
        return .merge(transfer, .cancel(id: CancelID.pairing))

      case .sessionDestinationDismissed:
        let transfer = transferDraft(from: state.session, state: &state)
        state.pendingDismissal = nil
        state.session = nil
        state.sessionDestination = nil
        return transfer

      case .draftTransferFinished(let id, let key, let draft, let result):
        guard let pending = state.pendingDraftTransfers[id],
          pending.key == key,
          pending.draft == draft
        else { return .none }
        state.pendingDraftTransfers[id] = nil
        switch result {
        case .saved:
          if let retained = state.retainedDraftTransfers[key],
            draft.supersedes(retained.draft)
          {
            state.retainedDraftTransfers[key] = nil
          }
          if state.retainedDraftTransfers.isEmpty, state.notice == .draftKept {
            state.notice = nil
          }
          if state.session?.composer.draftKey == key {
            return .send(.session(.composer(.restoreRetried)))
          }
        case .tooLarge, .failure:
          var failed = pending
          if case .failure(let failure) = result { failed.failure = failure }
          if let retained = state.retainedDraftTransfers[key],
            retained.draft.supersedes(failed.draft)
          {
            break
          }
          state.retainedDraftTransfers[key] = failed
          state.notice = .draftKept
        }
        return .none

      case .retryRetainedDrafts:
        guard !state.retainedDraftTransfers.isEmpty else { return .none }
        var effects: [Effect<Action>] = []
        for retained in state.retainedDraftTransfers.values {
          var retry = retained
          retry.id = uuid.uuid()
          state.pendingDraftTransfers[retry.id] = retry
          effects.append(transferEffect(id: retry.id, key: retry.key, draft: retry.draft))
        }
        state.retainedDraftTransfers = [:]
        return .merge(effects)

      case .noticeDismissed:
        state.notice = nil
        return .none

      case .connection(.delegate(.verified(let server, let info))):
        let servers = SavedServers.remembering(server, among: state.savedServers)
        let remembered = servers.first ?? server
        state.savedServer = remembered
        state.savedServers = servers
        _ = info
        if state.home?.serverID == remembered.persistenceID {
          state.home?.server = remembered
        }
        guard state.savedData.isReadable else {
          state.pendingSave = remembered
          return .none
        }
        return persistEffect(server: remembered, servers: servers)

      case .persisted(let saved, let list):
        if case .failure(let failure) = saved {
          state.notice = .couldNotSaveServer(failure)
        } else if case .failure(let failure) = list {
          state.notice = .couldNotSaveServer(failure)
        } else {
          state.notice = nil
        }
        return .none

      case .connection(.delegate(.projects(let server, let projects, let info))):
        _ = info
        var effects: [Effect<Action>] = [.send(.home(.projectsChanged(projects)))]
        if state.home?.serverID != server.persistenceID {
          state.home = HomeFeature.State(
            server: server,
            projects: projects,
            isPinned: state.isPinnedForUITest
          )
          effects.append(.send(.home(.task)))
        } else {
          state.home?.server = server
        }
        return .merge(effects)

      case .connection(.delegate(.available)):
        guard state.home != nil else { return .none }
        return .send(.home(.connectionResynchronized))

      case .connection(.delegate(.unavailable)):
        var effects: [Effect<Action>] = []
        if state.home != nil { effects.append(.send(.home(.connectionChanged(isConnected: false)))) }
        if state.session != nil { effects.append(.send(.session(.connectionChanged(isConnected: false)))) }
        return .merge(effects)

      case .connection(.delegate(.resynchronized)):
        var effects: [Effect<Action>] = []
        if state.home != nil { effects.append(.send(.home(.connectionResynchronized))) }
        if state.session != nil { effects.append(.send(.session(.connectionResynchronized))) }
        return .merge(effects)

      case .connection(.delegate(.sessionEvent(_, let event))):
        var effects: [Effect<Action>] = [.send(.home(.serverEvent(event)))]
        if state.session != nil { effects.append(.send(.session(.serverEvent(event)))) }
        return .merge(effects)

      case .connection(.delegate(.failed)):
        var effects: [Effect<Action>] = []
        if state.home != nil { effects.append(.send(.home(.connectionChanged(isConnected: false)))) }
        if state.session != nil { effects.append(.send(.session(.connectionChanged(isConnected: false)))) }
        return .merge(effects)

      case .connection:
        return .none

      case .home(.delegate(.openSession(let selection))):
        state.sessionDestination = selection
        guard let home = state.home, home.serverID == selection.serverID else { return .none }
        if state.session?.selection.id == selection.id,
          state.session?.server.persistenceID == selection.serverID
        {
          return .none
        }
        let transfer = transferDraft(from: state.session, state: &state)
        state.pendingDismissal = nil
        let id = state.nextSessionID
        state.nextSessionID += 1
        state.session = SessionFeature.State(
          id: id,
          server: home.server,
          selection: selection,
          session: home.session(selection.sessionID),
          isLive: homeIsLive(state),
          isPinned: state.isPinnedForUITest
        )
        raiseDraftWatermark(into: &state)
        return .merge(
          transfer,
          retryRetainedEffect(state: state),
          .send(.session(.task))
        )

      case .home(.delegate(.newSession(let directory))):
        guard let home = state.home else { return .none }
        let sessionID = uuid.uuid().uuidString.lowercased()
        let selection = SessionSelection(
          serverID: home.serverID,
          sessionID: sessionID,
          intent: .newSession(directory: directory)
        )
        state.sessionDestination = selection
        if state.session?.selection.id == selection.id,
          state.session?.server.persistenceID == selection.serverID
        {
          return .none
        }
        let transfer = transferDraft(from: state.session, state: &state)
        state.pendingDismissal = nil
        let id = state.nextSessionID
        state.nextSessionID += 1
        state.session = SessionFeature.State(
          id: id,
          server: home.server,
          selection: selection,
          session: nil,
          isLive: homeIsLive(state),
          isPinned: state.isPinnedForUITest
        )
        raiseDraftWatermark(into: &state)
        return .merge(
          transfer,
          retryRetainedEffect(state: state),
          .send(.session(.task))
        )

      case .home(.delegate(.switchServer(let server))):
        let transfer = transferDraft(from: state.session, state: &state)
        state.session = nil
        state.sessionDestination = nil
        state.pendingDismissal = nil
        return .merge(
          transfer,
          retryRetainedEffect(state: state),
          connect(to: server, state: &state)
        )

      case .home(.delegate(.disconnect)):
        let transfer = transferDraft(from: state.session, state: &state)
        state.connection = nil
        state.home = nil
        state.session = nil
        state.sessionDestination = nil
        state.pendingDismissal = nil
        return .merge(transfer, retryRetainedEffect(state: state))

      case .home:
        return .none

      case .session(.delegate(.dismiss)):
        guard let session = state.session else { return .none }
        let requestID = uuid.uuid()
        state.pendingDismissal = PendingSessionDismissal(
          requestID: requestID,
          serverID: session.server.persistenceID,
          sessionID: session.selection.sessionID
        )
        return .send(.session(.flushForDismiss(requestID)))

      case .session(.delegate(.dismissReady(let requestID, let serverID, let sessionID, let result))):
        guard let pending = state.pendingDismissal,
          pending.requestID == requestID,
          pending.serverID == serverID,
          pending.sessionID == sessionID,
          state.session?.server.persistenceID == serverID,
          state.session?.selection.sessionID == sessionID
        else { return .none }
        state.pendingDismissal = nil
        switch result {
        case .saved:
          state.session = nil
          state.sessionDestination = nil
          return .none
        case .tooLarge, .failure:
          state.notice = .couldNotSaveDraft
          return .none
        }

      case .session:
        return .none
      }
    }
    .ifLet(\.connection, action: \.connection) {
      ConnectionFeature()
    }
    .ifLet(\.home, action: \.home) {
      HomeFeature()
    }
    .ifLet(\.session, action: \.session) {
      SessionFeature()
    }
  }

  // MARK: Effects

  /// Saves a departing session's composer outside its child lifetime. The effect owns the captured
  /// draft, so replacing/disconnecting cannot cancel the last copy of unsent text.
  private func transferDraft(
    from session: SessionFeature.State?,
    state: inout State
  ) -> Effect<Action> {
    guard let session else { return .none }
    let composer = session.composer
    let key = composer.draftKey
    let draft = composer.persistedDraft
    let id = uuid.uuid()
    state.pendingDraftTransfers[id] = DraftTransfer(id: id, key: key, draft: draft)
    return transferEffect(id: id, key: key, draft: draft)
  }

  private func raiseDraftWatermark(into state: inout State) {
    guard let session = state.session else { return }
    let key = session.composer.draftKey
    var newest: DraftTransfer?
    for transfer in state.pendingDraftTransfers.values where transfer.key == key {
      if newest == nil || transfer.draft.supersedes(newest!.draft) { newest = transfer }
    }
    if let retained = state.retainedDraftTransfers[key],
      newest == nil || retained.draft.supersedes(newest!.draft)
    {
      newest = retained
    }
    guard let newest else { return }
    state.session?.composer.raiseContentWatermark(
      revision: newest.draft.revision,
      updatedAt: newest.draft.updatedAt
    )
  }

  private func retryRetainedEffect(state: State) -> Effect<Action> {
    state.retainedDraftTransfers.isEmpty ? .none : .send(.retryRetainedDrafts)
  }

  private func transferEffect(
    id: UUID,
    key: ComposerDraftKey,
    draft: ComposerDraft
  ) -> Effect<Action> {
    let drafts = composerDrafts
    return .run { send in
      let result: ComposerDraftSave
      if draft.isEmpty {
        result = await drafts.removeDeparting(draft, key)
      } else {
        result = await drafts.saveDeparting(draft, key)
      }
      await send(
        .draftTransferFinished(id: id, key: key, draft: draft, result: result)
      )
    }
  }

  private func persistEffect(server: OpenCodeServer, servers: [OpenCodeServer]) -> Effect<Action> {
    let store = store
    return .run { send in
      let saved = store.write(server, for: ServerSharedKeys.savedServer)
      let list = store.write(servers, for: ServerSharedKeys.savedServers)
      await send(.persisted(saved: saved, list: list))
    }
  }

  private func restoreEffect() -> Effect<Action> {
    let store = store
    return .run { send in
      await send(.restored(AppRestoreResult.read(store)))
    }
    .cancellable(id: CancelID.restore, cancelInFlight: true)
  }

  private func pathEffect() -> Effect<Action> {
    let path = networkPath
    return .run { send in
      for await update in path.updates() {
        await send(.networkPathChanged(update))
      }
    }
    .cancellable(id: CancelID.path, cancelInFlight: true)
  }

  // MARK: Connecting

  /// Home may read only while the app is in front, the path is usable and the shell has completed
  /// a connection. `connecting`, `loading`, `reconnecting` and `failed` are not live.
  private func homeIsLive(_ state: State) -> Bool {
    state.isInForeground
      && !state.networkPath.isOffline
      && state.connection?.phase == .connected
  }

  private func connect(to server: OpenCodeServer, state: inout State) -> Effect<Action> {
    let id = state.nextConnectionID
    state.nextConnectionID += 1
    state.pairingProblem = nil
    state.pasteProblem = nil
    state.home = nil
    state.session = nil
    state.sessionDestination = nil
    let cached = cachedSummaries()[server.persistenceID]
    state.connection = ConnectionFeature.State(
      id: id,
      server: server,
      phase: .connecting,
      projects: cached?.projects ?? [],
      isOffline: state.networkPath.isOffline,
      isInForeground: state.isInForeground,
      isPinned: state.isPinnedForUITest
    )
    return state.isPinnedForUITest ? .none : .send(.connection(.task))
  }

  // MARK: Pairing

  private func handlePairingText(
    _ text: String,
    requiresConfirmation: Bool,
    state: inout State
  ) -> Effect<Action> {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let link = PairingLink.decodeCopied(trimmed) else {
      if let unusable = PairingLink.unusableAddress(in: trimmed) {
        let problem = PairingProblem.unusableAddress(address: unusable.address, reason: unusable.problem)
        setPairingProblem(problem, requiresConfirmation: requiresConfirmation, state: &state)
      } else {
        let problem: PairingProblem = PairingLink.isPairingEndpoint(trimmed) ? .invalidCode : .notPairingText
        setPairingProblem(problem, requiresConfirmation: requiresConfirmation, state: &state)
      }
      return .none
    }
    if link.isLoopback {
      setPairingProblem(.loopback, requiresConfirmation: requiresConfirmation, state: &state)
      return .none
    }
    let normalized = link.normalizedForRedemption
    if requiresConfirmation {
      let replaced = normalized.replacedServers(saved: knownServers(state)).map(\.displayName)
      state.pendingPairing = PairingConfirmation(
        id: uuid.uuid(),
        link: normalized,
        replacedServerNames: replaced
      )
      state.pairingProblem = nil
      state.pasteProblem = nil
      return .none
    }
    return redeem(normalized, state: &state)
  }

  private func setPairingProblem(
    _ problem: PairingProblem,
    requiresConfirmation: Bool,
    state: inout State
  ) {
    if requiresConfirmation {
      state.pairingProblem = problem
    } else {
      state.pasteProblem = problem
    }
  }

  private func redeem(_ link: PairingLink, state: inout State) -> Effect<Action> {
    let attempt = state.nextPairingAttempt
    state.nextPairingAttempt += 1
    state.pairingAttempt = PairingAttempt(id: attempt, link: link)
    state.pendingPairing = nil
    state.pairingProblem = nil
    state.pasteProblem = nil
    state.connection = nil
    let client = client
    return .run { send in
      do {
        let server = try await client.redeemPairing(link)
        await send(.pairingFinished(attempt: attempt, result: .success(server)))
      } catch let error as OpenCodeClientError {
        await send(.pairingFinished(attempt: attempt, result: .failure(error)))
      } catch is CancellationError {
        return
      } catch {
        await send(.pairingFinished(attempt: attempt, result: .failure(OpenCodeClientError(.unreachable))))
      }
    }
    .cancellable(id: CancelID.pairing, cancelInFlight: true)
  }

  private func knownServers(_ state: State) -> [OpenCodeServer] {
    var seen = Set<String>()
    return ([state.savedServer].compactMap { $0 } + state.savedServers).filter {
      seen.insert($0.persistenceID).inserted
    }
  }

  private func cachedSummaries() -> [String: CachedServerSummary] {
    switch store.read(ServerSharedKeys.cachedSummaries) {
    case .value(let summaries): summaries
    case .missing, .undecodable, .failure: [:]
    }
  }

  /// A typed address without a scheme means plain HTTP on a LAN or tailnet.
  public static func withDefaultScheme(_ address: String) -> String {
    if address.isEmpty || address.contains("://") { return address }
    return "http://\(address)"
  }
}
