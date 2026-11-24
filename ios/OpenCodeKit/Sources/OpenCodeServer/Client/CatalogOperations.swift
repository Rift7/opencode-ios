import Foundation
import OpenCodeCore

// MARK: - Catalogue reads

extension Operations {
  /// `GET /api/model` and, when the server has it, `GET /api/model/default`.
  static func modelCatalog(
    _ server: OpenCodeServer,
    directory: String?,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> ModelCatalog {
    let query = directory.map { [("location[directory]", $0)] } ?? []
    let defaultPayload: ModelDefaultPayload? = try? await get(
      server,
      path: "/api/model/default",
      query: query,
      timeout: 20,
      environment: environment,
      policy: policy,
      feature: "default model"
    )
    let payload: DataPayload<[ModelInfoPayload]> = try await get(
      server,
      path: "/api/model",
      query: query,
      timeout: 20,
      environment: environment,
      policy: policy,
      feature: "model catalogue"
    )
    let models = payload.data
      .filter { $0.enabled && $0.status == "active" }
      .map(\.model)
    return ModelCatalog(models: models, defaultModel: defaultPayload?.data?.model)
  }

  static func switchModel(
    _ server: OpenCodeServer,
    sessionID: String,
    model: ModelRef,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws {
    struct Body: Encodable { var model: ModelRef }
    let data = try JSONEncoder().encode(Body(model: model))
    _ = try await raw(
      server,
      path: "/api/session/\(sessionID)/model",
      method: "POST",
      body: data,
      idempotency: .idempotent,
      environment: environment,
      policy: policy,
      feature: "switch model"
    )
  }

  static func agents(
    _ server: OpenCodeServer,
    directory: String?,
    primaryOnly: Bool,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> [ServerAgent] {
    let payload: DataPayload<[ServerAgent]> = try await get(
      server,
      path: "/api/agent",
      query: directory.map { [("location[directory]", $0)] } ?? [],
      timeout: 20,
      environment: environment,
      policy: policy,
      feature: "agents"
    )
    return primaryOnly ? ServerAgent.choosable(payload.data) : payload.data.filter { !$0.hidden }
  }

  static func switchAgent(
    _ server: OpenCodeServer,
    sessionID: String,
    agent: String,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws {
    struct Body: Encodable { var agent: String }
    let data = try JSONEncoder().encode(Body(agent: agent))
    _ = try await raw(
      server,
      path: "/api/session/\(sessionID)/agent",
      method: "POST",
      body: data,
      idempotency: .idempotent,
      environment: environment,
      policy: policy,
      feature: "switch agent"
    )
  }

  static func skills(
    _ server: OpenCodeServer,
    directory: String?,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> [ServerSkill] {
    let payload: DataPayload<[ServerSkill]> = try await get(
      server,
      path: "/api/skill",
      query: directory.map { [("location[directory]", $0)] } ?? [],
      timeout: 20,
      environment: environment,
      policy: policy,
      feature: "skills"
    )
    return payload.data
  }

  static func commands(
    _ server: OpenCodeServer,
    directory: String?,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> [ServerCommand] {
    let payload: DataPayload<[ServerCommand]> = try await get(
      server,
      path: "/api/command",
      query: directory.map { [("location[directory]", $0)] } ?? [],
      timeout: 20,
      environment: environment,
      policy: policy,
      feature: "commands"
    )
    return payload.data
  }

  /// `GET /api/fs/find?query=…&type=file&limit=…`: remote paths only.
  static func findFiles(
    _ server: OpenCodeServer,
    directory: String,
    query: String,
    limit: Int,
    environment: ClientEnvironment,
    policy: RetryPolicy
  ) async throws -> [ServerFileSuggestion] {
    let payload: DataPayload<[String]> = try await get(
      server,
      path: "/api/fs/find",
      query: [
        ("location[directory]", directory),
        ("query", query),
        ("type", "file"),
        ("limit", String(max(1, min(limit, 50)))),
      ],
      timeout: 15,
      environment: environment,
      policy: policy,
      feature: "file search"
    )
    return payload.data.map(ServerFileSuggestion.init(path:))
  }
}

private struct ModelDefaultPayload: Codable, Sendable {
  var data: ModelInfoPayload?

  var model: ServerModel? { data?.model }
}

private struct ModelInfoPayload: Codable, Sendable {
  var id: String?
  var modelID: String
  var providerID: String
  var canonical: String?
  var name: String
  var enabled: Bool
  var status: String
  var capabilities: Capabilities?
  var limit: Limit?
  var variants: [Variant]?

  struct Capabilities: Codable, Sendable { var input: [String]? }
  struct Limit: Codable, Sendable { var context: Int? }
  struct Variant: Codable, Sendable { var id: String }

  var model: ServerModel {
    ServerModel(
      modelID: modelID,
      providerID: providerID,
      name: name,
      inputs: capabilities?.input ?? [],
      contextLimit: limit?.context.flatMap { $0 > 0 ? $0 : nil },
      catalogID: id.flatMap { $0 == modelID ? nil : $0 },
      variants: (variants ?? []).map(\.id).filter { $0 != "default" },
      canonicalProviderID: canonical
    )
  }
}
