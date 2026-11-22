import ComposableArchitecture
import Foundation
import OpenCodeCore

/// `GET /api/info`: the fields every V2 server sends, and the addresses it listens on.
public struct ServerInfo: Sendable, Equatable, Codable {
  public var version: String
  public var pid: Int
  public var urls: [String]?

  public init(version: String, pid: Int, urls: [String]? = nil) {
    self.version = version
    self.pid = pid
    self.urls = urls
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
    events: @escaping @Sendable (OpenCodeServer, @escaping @Sendable (EventStreamPhase) async -> Void) ->
      AsyncThrowingStream<ServerEvent, any Error>
  ) {
    self.health = health
    self.redeemPairing = redeemPairing
    self.projects = projects
    self.sessionPage = sessionPage
    self.getSession = getSession
    self.activeSessionIDs = activeSessionIDs
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
    streamCapacity: Int = 128
  ) -> OpenCodeClient {
    Runtime(
      environment: ClientEnvironment(
        transport: transport,
        clock: clock,
        retryEnvironment: environment,
        streamCapacity: streamCapacity
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
      streamCapacity: 128
    )
  }
}

struct ClientEnvironment: Sendable {
  var transport: HTTPTransport
  var clock: ClockClient
  var retryEnvironment: RetryEnvironment
  var streamCapacity: Int
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

  // MARK: - Requests

  private static func get<Value: Decodable & Sendable>(
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
