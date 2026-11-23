import Foundation
import OpenCodeCore

// Composer sends, the first-send session create, queued-input withdrawal and the experimental wait.
extension Operations {
  static func sendPrompt(
    _ server: OpenCodeServer,
    sessionID: String,
    body: PromptBody,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws {
    let data: Data
    do {
      data = try JSONEncoder().encode(body)
    } catch {
      throw OpenCodeClientError(.undecodable(feature: "prompt body"))
    }
    _ = try await raw(
      server,
      path: "/api/session/\(sessionID)/prompt",
      method: "POST",
      body: data,
      timeout: 30,
      // The server admits a message ID once; a retry after a lost response cannot duplicate it.
      idempotency: .idempotent,
      environment: environment,
      policy: policy,
      feature: "prompt"
    )
  }

  static func createSession(
    _ server: OpenCodeServer,
    directory: String,
    id: String,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> OpenCodeSession {
    struct Location: Encodable { var directory: String }
    struct Body: Encodable {
      var id: String
      var location: Location
    }
    let data: Data
    do {
      data = try JSONEncoder().encode(Body(id: id, location: Location(directory: directory)))
    } catch {
      throw OpenCodeClientError(.undecodable(feature: "session create body"))
    }
    let payload: DataPayload<SessionPayload> = try await get(
      server,
      path: "/api/session",
      method: "POST",
      body: data,
      idempotency: .idempotent,
      environment: environment,
      policy: policy,
      feature: "session create"
    )
    return payload.data.session
  }

  static func cancelPendingInput(
    _ server: OpenCodeServer,
    sessionID: String,
    inputID: String,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws {
    _ = try await raw(
      server,
      path: "/api/session/\(sessionID)/inbox/\(inputID)",
      method: "DELETE",
      idempotency: .idempotent,
      environment: environment,
      policy: policy,
      feature: "cancel pending input"
    )
  }

  /// One long-poll endpoint plus the audited loop. Every poll is sent once; the loop is the retry
  /// layer, and it checks the run before spending the session-wait backoff.
  static func waitForIdle(
    _ server: OpenCodeServer,
    sessionID: String,
    environment: ClientEnvironment
  ) async throws {
    let environment = environment
    try await SessionWaitLoop.run(
      clock: environment.clock,
      wait: {
        _ = try await raw(
          server,
          path: "/api/experimental/session/\(sessionID)/wait",
          method: "POST",
          timeout: 25,
          idempotency: .idempotent,
          environment: environment,
          policy: .once,
          feature: "session wait"
        )
      },
      isActive: {
        try await sessionIsActive(
          server,
          sessionID: sessionID,
          environment: environment,
          policy: .once
        )
      }
    )
  }
}
