import ComposableArchitecture
import Foundation
import OpenCodeCore

/// `GET /api/info`: the fields every V2 server sends, and the addresses it listens on.
public struct ServerInfo: Sendable, Equatable, Codable {
  public var version: String
  public var pid: Int
  public var urls: [String]?
  /// Where the server keeps temporary files. Uploads need `tmp`; a server without it predates the
  /// write route and cannot accept attachments.
  public var paths: Paths?

  public struct Paths: Sendable, Equatable, Codable {
    public var tmp: String?

    public init(tmp: String? = nil) {
      self.tmp = tmp
    }
  }

  public init(version: String, pid: Int, urls: [String]? = nil, paths: Paths? = nil) {
    self.version = version
    self.pid = pid
    self.urls = urls
    self.paths = paths
  }

  /// See `OpenCodeClient.health`: `server.url` is the address that answered. A password, or a single
  /// address, needs nothing more. Without a password, an answer on a local network could come from
  /// any OpenCode server using the same address on whatever network the phone is on, so it must list
  /// one of our other addresses (one off the local network when we have one).
  public func identifies(_ server: OpenCodeServer) -> Bool {
    if !server.password.isEmpty || server.candidateURLs.count <= 1 { return true }
    let others = server.candidateURLs.filter { $0 != server.url }
    if !Self.isLocal(server.url) {
      guard let urls else { return true }
      return Self.overlap(urls, server.candidateURLs)
    }
    let remote = others.filter { !Self.isLocal($0) }
    guard let urls else { return remote.isEmpty }
    return Self.overlap(urls, remote.isEmpty ? others : remote)
  }

  private static func isLocal(_ url: String) -> Bool {
    guard let origin = ServerOrigin(address: url) else { return false }
    return origin.route == .localNetwork || origin.route == .loopback
  }

  private static func overlap(_ urls: [String], _ candidates: [String]) -> Bool {
    let ours = Set(candidates.compactMap(OpenCodeServer.origin))
    return urls.contains { url in
      guard let origin = OpenCodeServer.origin(url) else { return false }
      return ours.contains(origin)
    }
  }
}

/// `{token, device?: {name}}`: a missing or malformed device name never fails pairing.
public struct PairingSession: Sendable, Equatable {
  public var token: String
  public var deviceName: String?

  public init(token: String, deviceName: String? = nil) {
    self.token = token
    self.deviceName = deviceName
  }

  public static func decode(_ data: Data) throws -> PairingSession {
    struct Payload: Decodable {
      var token: String
      var device: Device?
      struct Device: Decodable { var name: String? }
    }
    let payload = try JSONDecoder().decode(Payload.self, from: data)
    let name = payload.device?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
    return PairingSession(token: payload.token, deviceName: (name?.isEmpty ?? true) ? nil : name)
  }
}

/// The V2 OpenCode server client: reads that return typed values, and the event stream.
///
/// Every call goes through the transport seam and `NetworkRetry` exactly once. A caller loop that
/// owns reconnects passes `RetryPolicy.once` so retries never nest. Phase 4 implements the reads the
/// connection and drawer need; the remaining routes have their wire models and are listed in
/// `docs/ios-migration/PROTOCOL_COVERAGE.md` for the phases that add their call sites.
public struct OpenCodeClient: Sendable {
  public var health: @Sendable (OpenCodeServer) async throws -> ServerInfo
  /// Redeems a one-time `opencode pair` link for a token-authenticated server, with its other addresses.
  public var redeemPairing: @Sendable (PairingLink) async throws -> OpenCodeServer
  public var projects: @Sendable (OpenCodeServer) async throws -> [ServerProject]
  public var sessionPage:
    @Sendable (OpenCodeServer, SessionPageRequest, Int) async throws -> SessionPage
  public var getSession: @Sendable (OpenCodeServer, String) async throws -> OpenCodeSession
  public var activeSessionIDs: @Sendable (OpenCodeServer) async throws -> Set<String>
  /// Root sessions waiting on the reader, from the location-scoped permission and form routes.
  public var attentionSessionIDs:
    @Sendable (OpenCodeServer, [OpenCodeSession], [String]) async throws -> Set<String>
  /// `POST /api/session/{id}/view`: a read receipt for the idle watermark the person saw.
  public var viewSession: @Sendable (OpenCodeServer, String, Int64) async throws -> Void
  /// `DELETE /api/session/{id}`.
  public var deleteSession: @Sendable (OpenCodeServer, String) async throws -> Void
  /// `POST /api/session/{id}/interrupt?resume=true`: whether a run was stopped.
  public var interruptSession: @Sendable (OpenCodeServer, String) async throws -> Bool
  /// Whether the server says this session is running.
  public var sessionIsActive: @Sendable (OpenCodeServer, String) async throws -> Bool
  /// The root and every subagent below it, with the running set.
  public var sessionFamily: @Sendable (OpenCodeServer, OpenCodeSession) async throws -> SessionFamily
  /// Permission and form requests waiting in the session's family and directory.
  public var pendingRequests:
    @Sendable (OpenCodeServer, OpenCodeSession, [String]) async throws -> PendingRequests
  public var replyPermission:
    @Sendable (OpenCodeServer, String, String, PermissionDecision, String?) async throws -> Void
  public var replyForm:
    @Sendable (OpenCodeServer, String, String, [String: FormValue], String?) async throws ->
      FormReplyOutcome
  public var cancelForm:
    @Sendable (OpenCodeServer, String, String, String?, String?) async throws -> FormReplyOutcome
  public var formState:
    @Sendable (OpenCodeServer, String, String, String?) async throws -> FormState
  public var pendingInputs: @Sendable (OpenCodeServer, String) async throws -> [PendingInput]
  public var setPendingInputDelivery:
    @Sendable (OpenCodeServer, String, String, PendingInput.Delivery) async throws -> Void
  public var runningShells: @Sendable (OpenCodeServer, String) async throws -> [ServerShell]
  public var shell: @Sendable (OpenCodeServer, String, String) async throws -> ServerShell
  public var shellOutput:
    @Sendable (OpenCodeServer, String, String, Int, Int) async throws -> ShellOutputPage
  public var stopShell: @Sendable (OpenCodeServer, String, String) async throws -> Void
  public var runningJobs: @Sendable (OpenCodeServer, String) async throws -> [ServerJob]
  public var cancelJob: @Sendable (OpenCodeServer, String) async throws -> Void
  /// The newest messages, oldest first, and the cursor of the older page.
  public var transcript: @Sendable (OpenCodeServer, String, Int) async throws -> TranscriptPage
  /// One older page: the first call with no cursor reads the newest window again, so the client
  /// can find its overlap before walking backwards.
  public var transcriptHistory:
    @Sendable (OpenCodeServer, String, String?) async throws -> TranscriptPage
  /// One message's rows, ordered oldest first.
  public var message: @Sendable (OpenCodeServer, String, String) async throws -> [TranscriptItem]
  /// `GET /api/experimental/media/{hash}`: an authenticated content-addressed blob.
  public var mediaBlob: @Sendable (OpenCodeServer, String) async throws -> Data
  /// `POST /api/experimental/fs/write`: streams a local file into the server's temporary directory.
  /// The same path is reused on a retry; the returned path is the server's absolute file path.
  public var uploadFile:
    @Sendable (OpenCodeServer, String?, URL, String, String, @escaping @Sendable (Int64) -> Void)
      async throws -> String
  /// `GET /api/fs/list`: folders and files inside a server directory.
  public var listDirectory: @Sendable (OpenCodeServer, String?) async throws -> DirectoryListing
  /// `GET /api/fs/read/{relative}`: one server file, bounded by the caller.
  public var readFile:
    @Sendable (OpenCodeServer, String, String, Int64) async throws -> Data
  /// `GET /api/model` and, where offered, `/api/model/default`.
  public var modelCatalog: @Sendable (OpenCodeServer, String?) async throws -> ModelCatalog
  /// `POST /api/session/{id}/model`.
  public var switchModel: @Sendable (OpenCodeServer, String, ModelRef) async throws -> Void
  /// `GET /api/agent`; `primaryOnly` keeps agents a session can start with.
  public var agents: @Sendable (OpenCodeServer, String?, Bool) async throws -> [ServerAgent]
  /// `POST /api/session/{id}/agent`.
  public var switchAgent: @Sendable (OpenCodeServer, String, String) async throws -> Void
  /// `GET /api/skill`.
  public var skills: @Sendable (OpenCodeServer, String?) async throws -> [ServerSkill]
  /// `GET /api/command`.
  public var commands: @Sendable (OpenCodeServer, String?) async throws -> [ServerCommand]
  /// `GET /api/fs/find`: remote path suggestions, bounded by `limit`.
  public var findFiles: @Sendable (OpenCodeServer, String, String, Int) async throws
    -> [ServerFileSuggestion]
  /// Admits one prompt under a client-made message ID, so a retry cannot create a second copy.
  public var sendPrompt: @Sendable (OpenCodeServer, String, PromptBody) async throws -> Void
  /// Creates a session in `directory`; `id` makes the create idempotent.
  public var createSession: @Sendable (OpenCodeServer, String, String) async throws -> OpenCodeSession
  /// Withdraws one undelivered inbox input. Already delivered is a no-op.
  public var cancelPendingInput: @Sendable (OpenCodeServer, String, String) async throws -> Void
  /// The audited experimental wait loop. It owns its single retry layer.
  public var waitForIdle: @Sendable (OpenCodeServer, String) async throws -> Void
  /// The long-lived event subscription. The flow throws on disconnect; the owner reconnects.
  /// `onPhase` is awaited before the reconnect loop acts, so a consumer can show the state and
  /// re-read REST before the next socket opens.
  public var events:
    @Sendable (OpenCodeServer, @escaping @Sendable (EventStreamPhase) async -> Void) ->
      AsyncThrowingStream<ServerEvent, any Error>

  public init(
    health: @escaping @Sendable (OpenCodeServer) async throws -> ServerInfo,
    redeemPairing: @escaping @Sendable (PairingLink) async throws -> OpenCodeServer,
    projects: @escaping @Sendable (OpenCodeServer) async throws -> [ServerProject],
    sessionPage: @escaping @Sendable (OpenCodeServer, SessionPageRequest, Int) async throws -> SessionPage,
    getSession: @escaping @Sendable (OpenCodeServer, String) async throws -> OpenCodeSession,
    activeSessionIDs: @escaping @Sendable (OpenCodeServer) async throws -> Set<String>,
    attentionSessionIDs: @escaping @Sendable (OpenCodeServer, [OpenCodeSession], [String]) async throws ->
      Set<String> = { _, _, _ in [] },
    viewSession: @escaping @Sendable (OpenCodeServer, String, Int64) async throws -> Void = { _, _, _ in
      throw OpenCodeClientError(.unsupported)
    },
    deleteSession: @escaping @Sendable (OpenCodeServer, String) async throws -> Void = { _, _ in
      throw OpenCodeClientError(.unsupported)
    },
    interruptSession: @escaping @Sendable (OpenCodeServer, String) async throws -> Bool = { _, _ in
      throw OpenCodeClientError(.unsupported)
    },
    sessionIsActive: @escaping @Sendable (OpenCodeServer, String) async throws -> Bool = { _, _ in
      throw OpenCodeClientError(.unsupported)
    },
    sessionFamily: @escaping @Sendable (OpenCodeServer, OpenCodeSession) async throws -> SessionFamily = {
      _, _ in throw OpenCodeClientError(.unsupported)
    },
    pendingRequests: @escaping @Sendable (OpenCodeServer, OpenCodeSession, [String]) async throws ->
      PendingRequests = { _, _, _ in throw OpenCodeClientError(.unsupported) },
    replyPermission: @escaping @Sendable (OpenCodeServer, String, String, PermissionDecision, String?)
      async throws -> Void = { _, _, _, _, _ in throw OpenCodeClientError(.unsupported) },
    replyForm: @escaping @Sendable (OpenCodeServer, String, String, [String: FormValue], String?)
      async throws -> FormReplyOutcome = { _, _, _, _, _ in throw OpenCodeClientError(.unsupported) },
    cancelForm: @escaping @Sendable (OpenCodeServer, String, String, String?, String?) async throws ->
      FormReplyOutcome = { _, _, _, _, _ in throw OpenCodeClientError(.unsupported) },
    formState: @escaping @Sendable (OpenCodeServer, String, String, String?) async throws -> FormState = {
      _, _, _, _ in throw OpenCodeClientError(.unsupported)
    },
    pendingInputs: @escaping @Sendable (OpenCodeServer, String) async throws -> [PendingInput] = {
      _, _ in throw OpenCodeClientError(.unsupported)
    },
    setPendingInputDelivery: @escaping @Sendable (
      OpenCodeServer, String, String, PendingInput.Delivery
    ) async throws -> Void = { _, _, _, _ in throw OpenCodeClientError(.unsupported) },
    runningShells: @escaping @Sendable (OpenCodeServer, String) async throws -> [ServerShell] = {
      _, _ in throw OpenCodeClientError(.unsupported)
    },
    shell: @escaping @Sendable (OpenCodeServer, String, String) async throws -> ServerShell = {
      _, _, _ in throw OpenCodeClientError(.unsupported)
    },
    shellOutput: @escaping @Sendable (OpenCodeServer, String, String, Int, Int) async throws ->
      ShellOutputPage = { _, _, _, _, _ in throw OpenCodeClientError(.unsupported) },
    stopShell: @escaping @Sendable (OpenCodeServer, String, String) async throws -> Void = {
      _, _, _ in throw OpenCodeClientError(.unsupported)
    },
    runningJobs: @escaping @Sendable (OpenCodeServer, String) async throws -> [ServerJob] = {
      _, _ in throw OpenCodeClientError(.unsupported)
    },
    cancelJob: @escaping @Sendable (OpenCodeServer, String) async throws -> Void = { _, _ in
      throw OpenCodeClientError(.unsupported)
    },
    transcript: @escaping @Sendable (OpenCodeServer, String, Int) async throws -> TranscriptPage = {
      _, _, _ in TranscriptPage(items: [])
    },
    transcriptHistory: @escaping @Sendable (OpenCodeServer, String, String?) async throws ->
      TranscriptPage = { _, _, _ in TranscriptPage(items: []) },
    message: @escaping @Sendable (OpenCodeServer, String, String) async throws -> [TranscriptItem] = {
      _, _, _ in []
    },
    mediaBlob: @escaping @Sendable (OpenCodeServer, String) async throws -> Data = { _, _ in
      throw OpenCodeClientError(.unsupported)
    },
    uploadFile: @escaping @Sendable (
      OpenCodeServer, String?, URL, String, String, @escaping @Sendable (Int64) -> Void
    ) async throws -> String = { _, _, _, _, _, _ in
      throw OpenCodeClientError(.unsupported)
    },
    listDirectory: @escaping @Sendable (OpenCodeServer, String?) async throws -> DirectoryListing = {
      _, _ in throw OpenCodeClientError(.unsupported)
    },
    readFile: @escaping @Sendable (OpenCodeServer, String, String, Int64) async throws -> Data = {
      _, _, _, _ in throw OpenCodeClientError(.unsupported)
    },
    modelCatalog: @escaping @Sendable (OpenCodeServer, String?) async throws -> ModelCatalog = {
      _, _ in throw OpenCodeClientError(.unsupported)
    },
    switchModel: @escaping @Sendable (OpenCodeServer, String, ModelRef) async throws -> Void = {
      _, _, _ in throw OpenCodeClientError(.unsupported)
    },
    agents: @escaping @Sendable (OpenCodeServer, String?, Bool) async throws -> [ServerAgent] = {
      _, _, _ in throw OpenCodeClientError(.unsupported)
    },
    switchAgent: @escaping @Sendable (OpenCodeServer, String, String) async throws -> Void = {
      _, _, _ in throw OpenCodeClientError(.unsupported)
    },
    skills: @escaping @Sendable (OpenCodeServer, String?) async throws -> [ServerSkill] = {
      _, _ in throw OpenCodeClientError(.unsupported)
    },
    commands: @escaping @Sendable (OpenCodeServer, String?) async throws -> [ServerCommand] = {
      _, _ in throw OpenCodeClientError(.unsupported)
    },
    findFiles: @escaping @Sendable (OpenCodeServer, String, String, Int) async throws
      -> [ServerFileSuggestion] = { _, _, _, _ in throw OpenCodeClientError(.unsupported) },
    sendPrompt: @escaping @Sendable (OpenCodeServer, String, PromptBody) async throws -> Void = {
      _, _, _ in throw OpenCodeClientError(.unsupported)
    },
    createSession: @escaping @Sendable (OpenCodeServer, String, String) async throws -> OpenCodeSession = {
      _, _, _ in throw OpenCodeClientError(.unsupported)
    },
    cancelPendingInput: @escaping @Sendable (OpenCodeServer, String, String) async throws -> Void = {
      _, _, _ in throw OpenCodeClientError(.unsupported)
    },
    waitForIdle: @escaping @Sendable (OpenCodeServer, String) async throws -> Void = { _, _ in
      throw OpenCodeClientError(.unsupported)
    },
    events: @escaping @Sendable (OpenCodeServer, @escaping @Sendable (EventStreamPhase) async -> Void) ->
      AsyncThrowingStream<ServerEvent, any Error>
  ) {
    self.health = health
    self.redeemPairing = redeemPairing
    self.projects = projects
    self.sessionPage = sessionPage
    self.getSession = getSession
    self.activeSessionIDs = activeSessionIDs
    self.attentionSessionIDs = attentionSessionIDs
    self.viewSession = viewSession
    self.deleteSession = deleteSession
    self.interruptSession = interruptSession
    self.sessionIsActive = sessionIsActive
    self.sessionFamily = sessionFamily
    self.pendingRequests = pendingRequests
    self.replyPermission = replyPermission
    self.replyForm = replyForm
    self.cancelForm = cancelForm
    self.formState = formState
    self.pendingInputs = pendingInputs
    self.setPendingInputDelivery = setPendingInputDelivery
    self.runningShells = runningShells
    self.shell = shell
    self.shellOutput = shellOutput
    self.stopShell = stopShell
    self.runningJobs = runningJobs
    self.cancelJob = cancelJob
    self.transcript = transcript
    self.transcriptHistory = transcriptHistory
    self.message = message
    self.mediaBlob = mediaBlob
    self.uploadFile = uploadFile
    self.listDirectory = listDirectory
    self.readFile = readFile
    self.modelCatalog = modelCatalog
    self.switchModel = switchModel
    self.agents = agents
    self.switchAgent = switchAgent
    self.skills = skills
    self.commands = commands
    self.findFiles = findFiles
    self.sendPrompt = sendPrompt
    self.createSession = createSession
    self.cancelPendingInput = cancelPendingInput
    self.waitForIdle = waitForIdle
    self.events = events
  }
}

extension OpenCodeClient: DependencyKey {
  /// The app's client: retry policies are the audited defaults.
  public static var liveValue: OpenCodeClient {
    resolve { environment in
      Runtime(environment: environment, defaultPolicy: .request)
    }
  }

  /// Inert: a test that has not overridden the client reaches nothing.
  public static let testValue = OpenCodeClient(
    health: { _ in throw OpenCodeClientError(.unreachable) },
    redeemPairing: { _ in throw OpenCodeClientError(.unreachable) },
    projects: { _ in throw OpenCodeClientError(.unreachable) },
    sessionPage: { _, _, _ in throw OpenCodeClientError(.unreachable) },
    getSession: { _, _ in throw OpenCodeClientError(.unreachable) },
    activeSessionIDs: { _ in throw OpenCodeClientError(.unreachable) },
    attentionSessionIDs: { _, _, _ in throw OpenCodeClientError(.unreachable) },
    viewSession: { _, _, _ in throw OpenCodeClientError(.unreachable) },
    deleteSession: { _, _ in throw OpenCodeClientError(.unreachable) },
    transcript: { _, _, _ in throw OpenCodeClientError(.unreachable) },
    transcriptHistory: { _, _, _ in throw OpenCodeClientError(.unreachable) },
    message: { _, _, _ in throw OpenCodeClientError(.unreachable) },
    events: { _, _ in
      AsyncThrowingStream { $0.finish(throwing: OpenCodeClientError(.unreachable)) }
    }
  )

  /// A real client over an explicit transport and clock, for tests and previews. Requests are sent
  /// once unless the test names a policy.
  public static func live(
    transport: HTTPTransport,
    clock: ClockClient,
    policy: RetryPolicy = .once,
    environment: RetryEnvironment = .online(),
    streamCapacity: Int = 128,
    mediaBlobLimit: Int64 = 25 * 1024 * 1024
  ) -> OpenCodeClient {
    Runtime(
      environment: ClientEnvironment(
        transport: transport,
        clock: clock,
        retryEnvironment: environment,
        streamCapacity: streamCapacity,
        mediaBlobLimit: mediaBlobLimit
      ),
      defaultPolicy: policy
    ).client
  }

  private static func resolve(
    _ make: @escaping @Sendable (ClientEnvironment) -> Runtime
  ) -> OpenCodeClient {
    let dependencies = DependencyReader()
    let runtime = make(dependencies.environment)
    return runtime.client
  }
}

extension DependencyValues {
  public var openCodeClient: OpenCodeClient {
    get { self[OpenCodeClient.self] }
    set { self[OpenCodeClient.self] = newValue }
  }
}

/// Reads the transport and clock from the current dependency context at call time, so a test's
/// `withDependencies` override reaches a client built before it ran.
private struct DependencyReader: Sendable {
  @Dependency(\.httpTransport) private var transport
  @Dependency(\.clock) private var clock
  @Dependency(\.networkPath) private var networkPath

  var environment: ClientEnvironment {
    ClientEnvironment(
      transport: transport,
      clock: clock,
      retryEnvironment: networkPath.retryEnvironment,
      streamCapacity: 128,
      mediaBlobLimit: 25 * 1024 * 1024
    )
  }
}

struct ClientEnvironment: Sendable {
  var transport: HTTPTransport
  var clock: ClockClient
  var retryEnvironment: RetryEnvironment
  var streamCapacity: Int
  var mediaBlobLimit: Int64
}

private struct Runtime: Sendable {
  let environment: ClientEnvironment
  let defaultPolicy: RetryPolicy

  var client: OpenCodeClient {
    let environment = environment
    let policy = defaultPolicy
    return OpenCodeClient(
      health: { server in try await Operations.health(server, environment: environment, policy: .once) },
      redeemPairing: { link in
        try await Operations.redeemPairing(link, environment: environment)
      },
      projects: { server in
        try await Operations.projects(server, environment: environment, policy: policy)
      },
      sessionPage: { server, request, limit in
        try await Operations.sessionPage(server, request: request, limit: limit, environment: environment, policy: policy)
      },
      getSession: { server, id in
        try await Operations.getSession(server, id: id, environment: environment, policy: policy)
      },
      activeSessionIDs: { server in
        try await Operations.activeSessionIDs(server, environment: environment, policy: policy)
      },
      attentionSessionIDs: { server, roots, directories in
        try await Operations.attentionSessionIDs(
          server,
          roots: roots,
          directories: directories,
          environment: environment,
          policy: policy
        )
      },
      viewSession: { server, sessionID, idle in
        try await Operations.viewSession(
          server,
          sessionID: sessionID,
          idle: idle,
          environment: environment,
          policy: policy
        )
      },
      deleteSession: { server, sessionID in
        try await Operations.deleteSession(
          server,
          sessionID: sessionID,
          environment: environment,
          policy: policy
        )
      },
      interruptSession: { server, sessionID in
        try await Operations.interruptSession(
          server,
          sessionID: sessionID,
          environment: environment,
          policy: .once
        )
      },
      sessionIsActive: { server, sessionID in
        try await Operations.sessionIsActive(
          server,
          sessionID: sessionID,
          environment: environment,
          policy: policy
        )
      },
      sessionFamily: { server, root in
        try await Operations.sessionFamily(
          server,
          root: root,
          environment: environment,
          policy: policy
        )
      },
      pendingRequests: { server, session, family in
        try await Operations.pendingRequests(
          server,
          session: session,
          family: family,
          environment: environment,
          policy: policy
        )
      },
      replyPermission: { server, sessionID, requestID, decision, message in
        try await Operations.replyPermission(
          server,
          sessionID: sessionID,
          requestID: requestID,
          decision: decision,
          message: message,
          environment: environment,
          policy: policy
        )
      },
      replyForm: { server, sessionID, formID, answer, directory in
        try await Operations.replyForm(
          server,
          sessionID: sessionID,
          formID: formID,
          answer: answer,
          directory: directory,
          environment: environment,
          policy: policy
        )
      },
      cancelForm: { server, sessionID, formID, message, directory in
        try await Operations.cancelForm(
          server,
          sessionID: sessionID,
          formID: formID,
          message: message,
          directory: directory,
          environment: environment,
          policy: policy
        )
      },
      formState: { server, sessionID, formID, directory in
        try await Operations.formState(
          server,
          sessionID: sessionID,
          formID: formID,
          directory: directory,
          environment: environment,
          policy: policy
        )
      },
      pendingInputs: { server, sessionID in
        try await Operations.pendingInputs(
          server,
          sessionID: sessionID,
          environment: environment,
          policy: policy
        )
      },
      setPendingInputDelivery: { server, sessionID, inputID, delivery in
        try await Operations.setPendingInputDelivery(
          server,
          sessionID: sessionID,
          inputID: inputID,
          delivery: delivery,
          environment: environment,
          policy: policy
        )
      },
      runningShells: { server, directory in
        try await Operations.runningShells(
          server,
          directory: directory,
          environment: environment,
          policy: policy
        )
      },
      shell: { server, directory, shellID in
        try await Operations.shell(
          server,
          directory: directory,
          shellID: shellID,
          environment: environment,
          policy: policy
        )
      },
      shellOutput: { server, directory, shellID, cursor, limit in
        try await Operations.shellOutput(
          server,
          directory: directory,
          shellID: shellID,
          cursor: cursor,
          limit: limit,
          environment: environment,
          policy: policy
        )
      },
      stopShell: { server, directory, shellID in
        try await Operations.stopShell(
          server,
          directory: directory,
          shellID: shellID,
          environment: environment,
          policy: policy
        )
      },
      runningJobs: { server, sessionID in
        try await Operations.runningJobs(
          server,
          sessionID: sessionID,
          environment: environment,
          policy: policy
        )
      },
      cancelJob: { server, jobID in
        try await Operations.cancelJob(
          server,
          jobID: jobID,
          environment: environment,
          policy: policy
        )
      },
      transcript: { server, sessionID, limit in
        try await Operations.transcript(
          server,
          sessionID: sessionID,
          limit: limit,
          environment: environment,
          policy: policy
        )
      },
      transcriptHistory: { server, sessionID, cursor in
        try await Operations.transcriptHistory(
          server,
          sessionID: sessionID,
          cursor: cursor,
          environment: environment,
          policy: policy
        )
      },
      message: { server, sessionID, messageID in
        try await Operations.message(
          server,
          sessionID: sessionID,
          messageID: messageID,
          environment: environment,
          policy: policy
        )
      },
      mediaBlob: { server, hash in
        try await Operations.mediaBlob(
          server,
          hash: hash,
          maximumBytes: environment.mediaBlobLimit,
          environment: environment,
          policy: policy
        )
      },
      uploadFile: { server, directory, fileURL, name, uploadID, onProgress in
        try await Operations.uploadFile(
          server,
          directory: directory,
          fileURL: fileURL,
          name: name,
          uploadID: uploadID,
          environment: environment,
          progress: onProgress
        )
      },
      listDirectory: { server, path in
        try await Operations.listDirectory(
          server,
          path: path,
          environment: environment,
          policy: policy
        )
      },
      readFile: { server, directory, relativePath, maximumBytes in
        try await Operations.readFile(
          server,
          directory: directory,
          relativePath: relativePath,
          maximumBytes: maximumBytes,
          environment: environment,
          policy: policy
        )
      },
      modelCatalog: { server, directory in
        try await Operations.modelCatalog(
          server,
          directory: directory,
          environment: environment,
          policy: policy
        )
      },
      switchModel: { server, sessionID, model in
        try await Operations.switchModel(
          server,
          sessionID: sessionID,
          model: model,
          environment: environment,
          policy: policy
        )
      },
      agents: { server, directory, primaryOnly in
        try await Operations.agents(
          server,
          directory: directory,
          primaryOnly: primaryOnly,
          environment: environment,
          policy: policy
        )
      },
      switchAgent: { server, sessionID, agent in
        try await Operations.switchAgent(
          server,
          sessionID: sessionID,
          agent: agent,
          environment: environment,
          policy: policy
        )
      },
      skills: { server, directory in
        try await Operations.skills(
          server,
          directory: directory,
          environment: environment,
          policy: policy
        )
      },
      commands: { server, directory in
        try await Operations.commands(
          server,
          directory: directory,
          environment: environment,
          policy: policy
        )
      },
      findFiles: { server, directory, query, limit in
        try await Operations.findFiles(
          server,
          directory: directory,
          query: query,
          limit: limit,
          environment: environment,
          policy: policy
        )
      },
      sendPrompt: { server, sessionID, body in
        try await Operations.sendPrompt(          server,
          sessionID: sessionID,
          body: body,
          environment: environment,
          policy: policy
        )
      },
      createSession: { server, directory, id in
        try await Operations.createSession(
          server,
          directory: directory,
          id: id,
          environment: environment,
          policy: policy
        )
      },
      cancelPendingInput: { server, sessionID, inputID in
        try await Operations.cancelPendingInput(
          server,
          sessionID: sessionID,
          inputID: inputID,
          environment: environment,
          policy: policy
        )
      },
      waitForIdle: { server, sessionID in
        try await Operations.waitForIdle(
          server,
          sessionID: sessionID,
          environment: environment
        )
      },
      events: { server, onPhase in
        EventStreamRunner(
          stream: EventStream(
            transport: environment.transport,
            clock: environment.clock,
            capacity: environment.streamCapacity
          ),
          environment: environment.retryEnvironment,
          onPhase: onPhase
        ).events(server: server)
      }
    )
  }
}

enum Operations {
  static func health(
    _ server: OpenCodeServer,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> ServerInfo {
    let info: ServerInfo = try await get(
      server,
      path: "/api/info",
      timeout: 3.5,
      redirectPolicy: .reject,
      environment: environment,
      policy: policy,
      feature: "server info"
    )
    guard info.identifies(server) else {
      throw OpenCodeClientError(.undecodable(feature: "server info"))
    }
    return info
  }

  static func redeemPairing(
    _ link: PairingLink,
    environment: ClientEnvironment
  ) async throws -> OpenCodeServer {
    let candidates = link.redeemOrigins
    guard !candidates.isEmpty else { throw OpenCodeClientError(.invalidURL) }

    // Which address the phone can reach depends on its network, so every listed one is tried at
    // once. The code is single-use: at most one redemption can succeed, so nothing is retried.
    let outcome: Result<OpenCodeServer, OpenCodeClientError> = await withTaskGroup(
      of: Result<OpenCodeServer, OpenCodeClientError>.self
    ) { group in
      for origin in candidates {
        group.addTask {
          do {
            return .success(
              try await Operations.redeemOne(origin: origin, code: link.code, environment: environment)
            )
          } catch let error as OpenCodeClientError {
            return .failure(error)
          } catch {
            return .failure(.init(.unreachable))
          }
        }
      }
      var failures: [OpenCodeClientError] = []
      while let result = await group.next() {
        switch result {
        case .success(let server):
          group.cancelAll()
          return Result.success(server)
        case .failure(let error):
          failures.append(error)
        }
      }
      return Result.failure(pairingFailure(failures))
    }

    var server = try outcome.get()
    let reported: [String]
    do {
      let info: ServerInfo = try await get(
        server,
        path: "/api/info",
        environment: environment,
        policy: .request,
        feature: "server info"
      )
      reported = info.urls ?? []
    } catch {
      // An older server without an address list still pairs.
      reported = []
    }
    let preferred = usableAddresses(candidates)
    server.preferredURLs = preferred
    server.alternateURLs = usableAddresses(candidates + reported).filter { $0 != server.url }
    return server
  }

  private static func redeemOne(
    origin: String,
    code: String,
    environment: ClientEnvironment
  ) async throws -> OpenCodeServer {
    // The connect route is unauthenticated; the single-use code is the credential.
    let anonymous = OpenCodeServer(url: origin, username: "opencode", password: "")
    let data = try await raw(
      anonymous,
      path: "/auth/connect/\(code)",
      timeout: 15,
      idempotency: .unsafe,
      redirectPolicy: .reject,
      environment: environment,
      policy: .once,
      feature: "pairing response"
    )
    let session: PairingSession
    do {
      session = try PairingSession.decode(data)
    } catch {
      throw OpenCodeClientError(.undecodable(feature: "pairing response"))
    }
    var server = OpenCodeServer(url: origin, username: "opencode", password: session.token)
    server.name = server.name ?? session.deviceName
    return server
  }

  /// The most telling reason no address redeemed the code: a server that answered beats one that
  /// could not be reached.
  private static func pairingFailure(_ failures: [OpenCodeClientError]) -> OpenCodeClientError {
    if failures.contains(where: { $0.statusCode == 401 }) {
      return OpenCodeClientError(.pairingExpired)
    }
    if failures.contains(where: { $0.statusCode == 404 }) {
      return OpenCodeClientError(.pairingUnsupported)
    }
    return failures.last ?? OpenCodeClientError(.unreachable)
  }

  /// Addresses without a trailing slash, loopback, or anything that is not an HTTP(S) address.
  private static func usableAddresses(_ addresses: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for address in addresses {
      let trimmed = address.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      guard let origin = ServerOrigin(address: trimmed), !origin.isLoopback else { continue }
      guard seen.insert(origin.dedupKey).inserted else { continue }
      result.append(origin.address)
    }
    return result
  }

  static func projects(
    _ server: OpenCodeServer,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> [ServerProject] {
    let payload: [ProjectPayload] = try await get(
      server,
      path: "/api/project",
      environment: environment,
      policy: policy,
      feature: "project list"
    )
    return payload.map(\.project)
  }

  static func sessionPage(
    _ server: OpenCodeServer,
    request: SessionPageRequest,
    limit: Int,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> SessionPage {
    var query: [(name: String, value: String)] = [("limit", String(limit))]
    switch request {
    case .first:
      query += [("parentID", "null"), ("archived", "false"), ("order", "desc")]
    case .search(let text):
      query += [
        ("parentID", "null"), ("archived", "false"), ("order", "desc"), ("search", text),
      ]
    case .after(let cursor):
      query.append(("cursor", cursor))
    }
    let payload: SessionsPayload = try await get(
      server,
      path: "/api/session",
      query: query,
      environment: environment,
      policy: policy,
      feature: "session page"
    )
    // A server that ignores `archived=false` still lists archived sessions.
    let sessions = payload.data.map(\.session).filter { !$0.isArchived && $0.parentID == nil }
    // An empty page ends the list even if the server offers another cursor.
    let next = payload.data.isEmpty ? nil : payload.cursor?.next
    return SessionPage(sessions: sessions, next: next)
  }

  static func getSession(
    _ server: OpenCodeServer,
    id: String,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> OpenCodeSession {
    let payload: DataPayload<SessionPayload> = try await get(
      server,
      path: "/api/session/\(id)",
      environment: environment,
      policy: policy,
      feature: "session"
    )
    return payload.data.session
  }

  static func activeSessionIDs(
    _ server: OpenCodeServer,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> Set<String> {
    let payload: DataPayload<[String: ActiveSession]> = try await get(
      server,
      path: "/api/session/active",
      environment: environment,
      policy: policy,
      feature: "active sessions"
    )
    return Set(payload.data.keys)
  }

  /// One read receipt. The server keeps the newest watermark, so repeating it is safe.
  static func viewSession(
    _ server: OpenCodeServer,
    sessionID: String,
    idle: Int64,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws {
    struct Body: Encodable { var idle: Int64 }
    let body: Data
    do {
      body = try JSONEncoder().encode(Body(idle: idle))
    } catch {
      throw OpenCodeClientError(.undecodable(feature: "view receipt"))
    }
    _ = try await raw(
      server,
      path: "/api/session/\(sessionID)/view",
      method: "POST",
      body: body,
      idempotency: .idempotent,
      environment: environment,
      policy: policy,
      feature: "view receipt"
    )
  }

  static func deleteSession(
    _ server: OpenCodeServer,
    sessionID: String,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws {
    _ = try await raw(
      server,
      path: "/api/session/\(sessionID)",
      method: "DELETE",
      environment: environment,
      policy: policy,
      feature: "delete session"
    )
  }

  /// Root sessions with a pending permission or form in any of `directories`.
  ///
  /// The catalogue of request fields belongs to the request-review phase; this read only needs
  /// `sessionID`, so it decodes the envelope loosely and never trusts a request shape it does not
  /// own. At most `maximumAttentionDirectories` locations are asked, once each.
  static func attentionSessionIDs(
    _ server: OpenCodeServer,
    roots: [OpenCodeSession],
    directories: [String],
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> Set<String> {
    let requested = Array(
      directories
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .reduce(into: [String]()) { unique, directory in
          if !unique.contains(directory) { unique.append(directory) }
        }
        .prefix(maximumAttentionDirectories)
    )
    guard !requested.isEmpty else { return [] }

    let pending: [String] = try await withThrowingTaskGroup(of: [String].self) { group in
      for directory in requested {
        group.addTask {
          try await pendingSessionIDs(in: directory, server: server, environment: environment, policy: policy)
        }
      }
      var ids: [String] = []
      for try await found in group {
        ids += found
      }
      return ids
    }

    var knownRoots = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0.id) })
    var result = Set<String>()
    for sessionID in Set(pending) where sessionID != "global" {
      result.insert(try await rootSessionID(sessionID, server: server, known: &knownRoots, environment: environment, policy: policy))
    }
    return result
  }

  private static let maximumAttentionDirectories = 8
  private static let locationBootTimeout: TimeInterval = 60

  private static func pendingSessionIDs(
    in directory: String,
    server: OpenCodeServer,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> [String] {
    let query = [(name: "location[directory]", value: directory)]
    async let permissions: DataPayload<[JSONValue]> = get(
      server,
      path: "/api/permission/request",
      query: query,
      timeout: locationBootTimeout,
      environment: environment,
      policy: policy,
      feature: "pending permissions"
    )
    async let forms: DataPayload<[JSONValue]> = get(
      server,
      path: "/api/form",
      query: query,
      timeout: locationBootTimeout,
      environment: environment,
      policy: policy,
      feature: "pending forms"
    )
    let (permissionPayload, formPayload) = try await (permissions, forms)
    return (permissionPayload.data + formPayload.data).compactMap { $0["sessionID"]?.stringValue }
  }

  private static func rootSessionID(
    _ sessionID: String,
    server: OpenCodeServer,
    known: inout [String: String],
    environment: ClientEnvironment,
    policy: RetryPolicy,
    depth: Int = 0
  ) async throws -> String {
    var current = sessionID
    var lineage: [String] = []
    var visited = Set<String>()
    while visited.insert(current).inserted {
      if let root = known[current] {
        for id in lineage { known[id] = root }
        return root
      }
      lineage.append(current)
      guard depth + lineage.count <= 8 else { break }
      do {
        let session = try await getSession(
          server,
          id: current,
          environment: environment,
          policy: policy
        )
        if let parentID = session.parentID {
          current = parentID
        } else {
          for id in lineage { known[id] = session.id }
          return session.id
        }
      } catch let error as OpenCodeClientError {
        if case .status(404) = error.failure { break }
        throw error
      }
    }
    return sessionID
  }

  // MARK: - Requests

  static func get<Value: Decodable & Sendable>(
    _ server: OpenCodeServer,
    path: String,
    query: [(name: String, value: String)] = [],
    method: String = "GET",
    body: Data? = nil,
    timeout: TimeInterval = 10,
    idempotency: RequestIdempotency? = nil,
    redirectPolicy: HTTPRedirectPolicy = .followSameOrigin,
    environment: ClientEnvironment,
    policy: RetryPolicy,
    feature: String
  ) async throws -> Value {
    let data = try await raw(
      server,
      path: path,
      query: query,
      method: method,
      body: body,
      timeout: timeout,
      idempotency: idempotency,
      redirectPolicy: redirectPolicy,
      environment: environment,
      policy: policy,
      feature: feature
    )
    do {
      return try JSONDecoder().decode(Value.self, from: data)
    } catch {
      throw OpenCodeClientError(.undecodable(feature: feature))
    }
  }

  static func raw(
    _ server: OpenCodeServer,
    path: String,
    query: [(name: String, value: String)] = [],
    method: String = "GET",
    body: Data? = nil,
    timeout: TimeInterval = 10,
    idempotency: RequestIdempotency? = nil,
    redirectPolicy: HTTPRedirectPolicy = .followSameOrigin,
    environment: ClientEnvironment,
    policy: RetryPolicy,
    feature: String
  ) async throws -> Data {
    guard let request = server.request(
      path: path,
      query: query,
      method: method,
      body: body,
      timeout: timeout,
      redirectPolicy: redirectPolicy
    ) else {
      throw OpenCodeClientError(.invalidURL)
    }
    let idempotency = idempotency ?? RequestIdempotency.forMethod(method)
    let log = AppLog(category: .network)

    return try await NetworkRetry.run(
      policy: policy,
      idempotency: idempotency,
      clock: environment.clock,
      environment: environment.retryEnvironment
    ) { attempt in
      let response: HTTPResponse
      do {
        response = try await environment.transport.send(request)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        let clientError = Self.clientError(for: error)
        log.event(
          .networkFailed,
          [
            LogField("attempt", .count(attempt)),
            LogField("status", .status(clientError.statusCode ?? 0)),
          ]
        )
        throw clientError
      }
      guard (200...299).contains(response.status) else {
        let error = OpenCodeClientError(
          .status(response.status),
          retryAfter: OpenCodeClientError.retryAfter(header: response.header("retry-after")),
          isLocationMissing: OpenCodeClientError.isLocationMissing(
            status: response.status,
            body: response.body
          )
        )
        log.event(
          .networkFailed,
          [
            LogField("attempt", .count(attempt)),
            LogField("status", .status(response.status)),
            LogField("locationMissing", .flag(error.isLocationMissing)),
          ]
        )
        throw error
      }
      // A 2xx that is a web page means this address is not serving the V2 API. Keep that distinct
      // from a decode mismatch, a 401 and a transport failure so a connection screen can say which.
      if let contentType = response.header("content-type")?.lowercased(),
        contentType.hasPrefix("text/html") || contentType.hasPrefix("application/xhtml+xml")
      {
        throw OpenCodeClientError(.incompatibleAPI(feature: feature))
      }
      log.event(
        .networkResponse,
        [
          LogField("attempt", .count(attempt)),
          LogField("status", .status(response.status)),
          LogField("bytes", .count(response.body.count)),
        ]
      )
      return response.body
    }
  }

  private static func clientError(for error: any Error) -> OpenCodeClientError {
    if let error = error as? OpenCodeClientError { return error }
    if let failure = TransportFailure(error) { return OpenCodeClientError(.transport(failure)) }
    return OpenCodeClientError(.unreachable)
  }
}
