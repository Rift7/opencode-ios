import Foundation
import OpenCodeCore

// Session-phase routes: family discovery, request review, shells and background jobs. Every read
// goes through the one transport and one retry layer; reply flows own their resend so they call
// their reads with `RetryPolicy.once`.
extension Operations {
  // MARK: - Run lifecycle

  static func interruptSession(
    _ server: OpenCodeServer,
    sessionID: String,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> Bool {
    let payload: InterruptResult = try await get(
      server,
      path: "/api/session/\(sessionID)/interrupt",
      query: [("resume", "true")],
      method: "POST",
      idempotency: .unsafe,
      environment: environment,
      policy: policy,
      feature: "interrupt"
    )
    return payload.interrupted
  }

  static func sessionIsActive(
    _ server: OpenCodeServer,
    sessionID: String,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> Bool {
    let payload: DataPayload<[String: ActiveSession]> = try await get(
      server,
      path: "/api/session/active",
      environment: environment,
      policy: policy,
      feature: "active sessions"
    )
    return payload.data[sessionID] != nil
  }

  // MARK: - Family

  /// Breadth-first child discovery with the audited bounds: six child pages in flight, at most
  /// 100 family sessions, one visited set. Responses are consumed in queue order, never completion
  /// order, so the family reads the same on every run.
  static func sessionFamily(
    _ server: OpenCodeServer,
    root: OpenCodeSession,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> SessionFamily {
    let activeRequest = Task {
      try await activeSessionIDs(server, environment: environment, policy: policy)
    }

    var sessions: [OpenCodeSession] = [root]
    var queue: [String] = [root.id]
    var visited: Set<String> = [root.id]
    var index = 0
    let maximumSessions = 100
    let batchSize = 6

    while index < queue.count && sessions.count < maximumSessions {
      let end = min(index + batchSize, queue.count)
      let parents = Array(queue[index..<end])
      index = end

      let pages = try await withThrowingTaskGroup(
        of: (Int, [SessionPayload]).self,
        returning: [[SessionPayload]].self
      ) { group in
        for (offset, parentID) in parents.enumerated() {
          group.addTask {
            let payload: DataPayload<[SessionPayload]> = try await get(
              server,
              path: "/api/session",
              query: [("parentID", parentID), ("order", "desc"), ("limit", "100")],
              environment: environment,
              policy: policy,
              feature: "session family"
            )
            return (offset, payload.data)
          }
        }
        var ordered = Array<[SessionPayload]?>(repeating: nil, count: parents.count)
        for try await (offset, payload) in group {
          ordered[offset] = payload
        }
        return ordered.compactMap { $0 }
      }

      for page in pages {
        guard sessions.count < maximumSessions else { break }
        for child in page.map(\.session) where visited.insert(child.id).inserted {
          guard sessions.count < maximumSessions else { break }
          sessions.append(child)
          queue.append(child.id)
        }
      }
    }

    let active = (try? await activeRequest.value) ?? []
    let running = await activeDescendants(
      server,
      family: sessions,
      activeIDs: active,
      environment: environment,
      policy: policy
    )
    var known = Set(sessions.map(\.id))
    for session in running where known.insert(session.id).inserted {
      sessions.append(session)
    }
    return SessionFamily(root: root, sessions: sessions, activeSessionIDs: active)
  }

  /// Running descendants the capped walk missed. Parents are followed through metadata reads,
  /// at most 24 lookups in batches of six; a failed lookup ends the search rather than failing a
  /// family that already loaded.
  private static func activeDescendants(
    _ server: OpenCodeServer,
    family: [OpenCodeSession],
    activeIDs: Set<String>,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async -> [OpenCodeSession] {
    var parents: [String: String?] = [:]
    for session in family { parents[session.id] = session.parentID }
    var members = Set(family.map(\.id))
    var fetched: [String: OpenCodeSession] = [:]
    var attempted = Set<String>()
    var found: [OpenCodeSession] = []
    let limit = 24
    let batchSize = 6

    while true {
      var unknown: [String] = []
      for start in activeIDs.sorted() where !members.contains(start) {
        var chain: [String] = []
        var id = start
        var reachesFamily = false
        while !chain.contains(id) {
          if members.contains(id) {
            reachesFamily = true
            break
          }
          chain.append(id)
          guard let entry = parents[id] else {
            if !attempted.contains(id) { unknown.append(id) }
            break
          }
          guard let parent = entry else { break }
          id = parent
        }
        guard reachesFamily else { continue }
        let missing = chain.filter { fetched[$0] == nil }
        if !missing.isEmpty {
          unknown += missing.filter { !attempted.contains($0) }
          continue
        }
        for member in chain.reversed() where members.insert(member).inserted {
          if let session = fetched[member] { found.append(session) }
        }
      }

      let candidates = Array(Set(unknown)).sorted().filter { !attempted.contains($0) }
      let remaining = max(0, limit - attempted.count)
      let batch = Array(candidates.prefix(min(batchSize, remaining)))
      attempted.formUnion(batch)
      guard !batch.isEmpty else { return found }

      do {
        let results = try await withThrowingTaskGroup(
          of: (String, OpenCodeSession?).self,
          returning: [(String, OpenCodeSession?)].self
        ) { group in
          for id in batch {
            group.addTask {
              do {
                return (id, try await getSession(server, id: id, environment: environment, policy: policy))
              } catch let error as OpenCodeClientError where error.statusCode == 404 {
                return (id, nil)
              }
            }
          }
          var values: [(String, OpenCodeSession?)] = []
          for try await value in group { values.append(value) }
          return values
        }
        for (id, session) in results {
          if let session {
            parents[id] = session.parentID
            fetched[id] = session
          } else {
            parents.updateValue(nil, forKey: id)
          }
        }
      } catch {
        AppLog(category: .network).event(
          .familyAncestryStopped,
          [LogField("lookups", .count(attempted.count))]
        )
        return found
      }
    }
  }

  // MARK: - Requests

  static func pendingRequests(
    _ server: OpenCodeServer,
    session: OpenCodeSession,
    family: [String],
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> PendingRequests {
    let directory = session.directory
    let query = [("location[directory]", directory)]
    async let permissions: DataPayload<[PermissionRequest]> = get(
      server,
      path: "/api/permission/request",
      query: query,
      timeout: locationRequestTimeout,
      environment: environment,
      policy: policy,
      feature: "pending permissions"
    )
    async let forms: DataPayload<[FormRequest]> = get(
      server,
      path: "/api/form",
      query: query,
      timeout: locationRequestTimeout,
      environment: environment,
      policy: policy,
      feature: "pending forms"
    )
    let (permissionPayload, formPayload) = try await (permissions, forms)
    let familyIDs = Set(family)
    return PendingRequests(
      permissions: permissionPayload.data.filter { familyIDs.contains($0.sessionID) },
      forms: formPayload.data.filter {
        $0.sessionID == "global" || familyIDs.contains($0.sessionID)
      }
    )
  }

  static func replyPermission(
    _ server: OpenCodeServer,
    sessionID: String,
    requestID: String,
    decision: PermissionDecision,
    message: String?,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws {
    struct Body: Encodable {
      var decision: PermissionDecision
      var message: String?
    }
    let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
    let reason = decision == .reject ? (trimmed?.isEmpty ?? true ? nil : trimmed) : nil
    let body: Data
    do {
      body = try JSONEncoder().encode(Body(decision: decision, message: reason))
    } catch {
      throw OpenCodeClientError(.undecodable(feature: "permission response"))
    }
    _ = try await raw(
      server,
      path: "/api/session/\(sessionID)/permission/\(requestID)/reply",
      method: "POST",
      body: body,
      idempotency: .unsafe,
      environment: environment,
      policy: policy,
      feature: "permission response"
    )
  }

  static func replyForm(
    _ server: OpenCodeServer,
    sessionID: String,
    formID: String,
    answer: [String: FormValue],
    directory: String?,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> FormReplyOutcome {
    struct Body: Encodable { var answer: [String: FormValue] }
    let body: Data
    do {
      body = try JSONEncoder().encode(Body(answer: answer))
    } catch {
      throw OpenCodeClientError(.undecodable(feature: "form response"))
    }
    return try await settleForm(
      server,
      sessionID: sessionID,
      formID: formID,
      directory: directory,
      wanted: .answered(answer),
      environment: environment,
      sent: {
        _ = try await raw(
          server,
          path: "/api/session/\(sessionID)/form/\(formID)/reply",
          query: formQuery(sessionID: sessionID, directory: directory),
          method: "POST",
          body: body,
          idempotency: .unsafe,
          environment: environment,
          policy: .once,
          feature: "form response"
        )
      }
    )
  }

  static func cancelForm(
    _ server: OpenCodeServer,
    sessionID: String,
    formID: String,
    message: String?,
    directory: String?,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> FormReplyOutcome {
    let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
    var query = formQuery(sessionID: sessionID, directory: directory)
    if let trimmed, !trimmed.isEmpty { query.append(("message", trimmed)) }
    return try await settleForm(
      server,
      sessionID: sessionID,
      formID: formID,
      directory: directory,
      wanted: .cancelled(trimmed),
      environment: environment,
      sent: {
        _ = try await raw(
          server,
          path: "/api/session/\(sessionID)/form/\(formID)",
          query: query,
          method: "DELETE",
          idempotency: .unsafe,
          environment: environment,
          policy: .once,
          feature: "form dismissal"
        )
      }
    )
  }

  static func formState(
    _ server: OpenCodeServer,
    sessionID: String,
    formID: String,
    directory: String?,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> FormState {
    struct Detail: Codable { var state: FormState }
    let payload: DataPayload<Detail> = try await get(
      server,
      path: "/api/session/\(sessionID)/form/\(formID)",
      query: formQuery(sessionID: sessionID, directory: directory),
      environment: environment,
      policy: policy,
      feature: "form state"
    )
    return payload.data.state
  }

  /// A reply that landed answers a repeat with 409. When the connection broke after sending, the
  /// form's own state decides whether it took; only a still-pending form is sent once more.
  private static func settleForm(
    _ server: OpenCodeServer,
    sessionID: String,
    formID: String,
    directory: String?,
    wanted: FormSettlement,
    environment: ClientEnvironment,
    sent: () async throws -> Void
  ) async throws -> FormReplyOutcome {
    var resent = false
    while true {
      do {
        try await sent()
        return .settled
      } catch let error as OpenCodeClientError {
        if error.statusCode == 404 && !error.isLocationMissing {
          return .conflict(.noLongerWaiting)
        }
        if !error.mayHaveReachedServer && error.statusCode != 409 { throw error }
        let state: FormState
        do {
          state = try await formState(
            server,
            sessionID: sessionID,
            formID: formID,
            directory: directory,
            environment: environment,
            policy: .once
          )
        } catch let read as OpenCodeClientError {
          if read.statusCode == 404 && !read.isLocationMissing {
            return .conflict(.noLongerWaiting)
          }
          throw error
        }
        if wanted.matches(state) { return .settled }
        if state.status != .pending { return .conflict(wanted.conflict) }
        if error.statusCode == 409 || resent { throw error }
        resent = true
      }
    }
  }

  // MARK: - Inbox

  static func pendingInputs(
    _ server: OpenCodeServer,
    sessionID: String,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> [PendingInput] {
    let payload: PendingInputsPayload = try await get(
      server,
      path: "/api/session/\(sessionID)/inbox",
      environment: environment,
      policy: policy,
      feature: "pending inputs"
    )
    return payload.data.compactMap { item in
      if item.type == "move" { return nil }
      let delivery = PendingInput.Delivery(rawValue: item.delivery ?? "steer") ?? .steer
      switch item.type {
      case "compaction":
        return PendingInput(id: item.id, text: "", delivery: delivery, isCompaction: true)
      case "synthetic":
        return PendingInput(
          id: item.id,
          text: item.payload?.description ?? "",
          delivery: delivery
        )
      default:
        return PendingInput(
          id: item.id,
          text: item.payload?.text ?? "",
          delivery: delivery
        )
      }
    }
  }

  static func setPendingInputDelivery(
    _ server: OpenCodeServer,
    sessionID: String,
    inputID: String,
    delivery: PendingInput.Delivery,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws {
    struct Body: Encodable { var delivery: String }
    let body: Data
    do {
      body = try JSONEncoder().encode(Body(delivery: delivery.rawValue))
    } catch {
      throw OpenCodeClientError(.undecodable(feature: "pending input delivery"))
    }
    do {
      _ = try await raw(
        server,
        path: "/api/session/\(sessionID)/inbox/\(inputID)",
        method: "PATCH",
        body: body,
        idempotency: .unsafe,
        environment: environment,
        policy: policy,
        feature: "pending input delivery"
      )
    } catch let error as OpenCodeClientError {
      guard error.mayHaveReachedServer || error.statusCode == 409 else { throw error }
      let inbox = try await pendingInputs(
        server,
        sessionID: sessionID,
        environment: environment,
        policy: .once
      )
      guard inbox.contains(where: { $0.id == inputID && $0.delivery == delivery }) else {
        throw error
      }
    }
  }

  // MARK: - Shells and jobs

  static func runningShells(
    _ server: OpenCodeServer,
    directory: String,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> [ServerShell] {
    let payload: DataPayload<[ShellInfoPayload]> = try await get(
      server,
      path: "/api/shell",
      query: [("location[directory]", directory)],
      timeout: 20,
      environment: environment,
      policy: policy,
      feature: "shell list"
    )
    return payload.data.filter { $0.status == "running" }.map { $0.shell(isListed: true) }
  }

  static func shell(
    _ server: OpenCodeServer,
    directory: String,
    shellID: String,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> ServerShell {
    let payload: DataPayload<ShellInfoPayload> = try await get(
      server,
      path: "/api/shell/\(shellID)",
      query: [("location[directory]", directory)],
      environment: environment,
      policy: policy,
      feature: "shell"
    )
    return payload.data.shell(isListed: true)
  }

  static func shellOutput(
    _ server: OpenCodeServer,
    directory: String,
    shellID: String,
    cursor: Int,
    limit: Int,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> ShellOutputPage {
    let payload: DataPayload<ShellOutputPage> = try await get(
      server,
      path: "/api/shell/\(shellID)/output",
      query: [
        ("location[directory]", directory),
        ("cursor", String(cursor)),
        ("limit", String(limit)),
      ],
      timeout: 20,
      environment: environment,
      policy: policy,
      feature: "shell output"
    )
    return payload.data
  }

  static func stopShell(
    _ server: OpenCodeServer,
    directory: String,
    shellID: String,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws {
    _ = try await raw(
      server,
      path: "/api/shell/\(shellID)",
      query: [("location[directory]", directory)],
      method: "DELETE",
      idempotency: .unsafe,
      environment: environment,
      policy: policy,
      feature: "stop shell"
    )
  }

  static func runningJobs(
    _ server: OpenCodeServer,
    sessionID: String,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> [ServerJob] {
    let payload: DataPayload<[JobInfoPayload]> = try await get(
      server,
      path: "/api/experimental/job",
      query: [
        ("sessionID", sessionID), ("descendants", "true"), ("status", "running"),
      ],
      environment: environment,
      policy: policy,
      feature: "background jobs"
    )
    return payload.data.map(\.job).filter(\.isRunning)
  }

  static func cancelJob(
    _ server: OpenCodeServer,
    jobID: String,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws {
    _ = try await raw(
      server,
      path: "/api/experimental/job/\(jobID)/cancel",
      method: "POST",
      idempotency: .idempotent,
      environment: environment,
      policy: policy,
      feature: "cancel job"
    )
  }

  private static let locationRequestTimeout: TimeInterval = 60

  private static func formQuery(
    sessionID: String,
    directory: String?
  ) -> [(name: String, value: String)] {
    guard sessionID == "global", let directory, !directory.isEmpty else { return [] }
    return [("location[directory]", directory)]
  }
}

private struct PendingInputsPayload: Codable, Sendable {
  struct Item: Codable, Sendable {
    struct Payload: Codable, Sendable {
      var text: String?
      var description: String?
    }

    var id: String
    var type: String
    var payload: Payload?
    var delivery: String?
  }

  var data: [Item]
}
