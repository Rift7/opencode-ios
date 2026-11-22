import Foundation
import OpenCodeCore

// Transcript reads. The newest window and older pages share the same route; only the query
// differs, and the older page uses the audited 20 s allowance for a message-heavy response.
extension Operations {
  /// Messages per older page: two top-edge steps of the reader.
  static let historyPageLimit = 80

  static func transcript(
    _ server: OpenCodeServer,
    sessionID: String,
    limit: Int,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> TranscriptPage {
    let data = try await raw(
      server,
      path: "/api/session/\(sessionID)/message",
      query: [("order", "desc"), ("limit", "\(limit)")],
      environment: environment,
      policy: policy,
      feature: "transcript"
    )
    return try TranscriptDecoder.page(from: data)
  }

  static func transcriptHistory(
    _ server: OpenCodeServer,
    sessionID: String,
    cursor: String?,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> TranscriptPage {
    var query: [(name: String, value: String)] = [("limit", "\(historyPageLimit)")]
    if let cursor {
      query.append(("cursor", cursor))
    } else {
      query.append(("order", "desc"))
    }
    let data = try await raw(
      server,
      path: "/api/session/\(sessionID)/message",
      query: query,
      timeout: 20,
      environment: environment,
      policy: policy,
      feature: "transcript history"
    )
    return try TranscriptDecoder.page(from: data)
  }

  static func message(
    _ server: OpenCodeServer,
    sessionID: String,
    messageID: String,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> [TranscriptItem] {
    let data = try await raw(
      server,
      path: "/api/session/\(sessionID)/message/\(messageID)",
      environment: environment,
      policy: policy,
      feature: "message"
    )
    return try TranscriptDecoder.message(from: data)
  }
}
