import Foundation
import OpenCodeCore
import OpenCodeServer
import Testing

@Suite("Catalogue client")
struct CatalogClientTests {
  private let server = OpenCodeServer(url: "http://10.0.0.2:4096", password: "token")

  private func client(
    _ handler: @escaping @Sendable (HTTPRequest, Int) async throws -> (status: Int, body: Data)
  ) -> (OpenCodeClient, RequestLog) {
    let log = RequestLog()
    return (
      OpenCodeClient.live(
        transport: Fixtures.transport(log: log, handler: handler),
        clock: .testValue,
        policy: .once
      ),
      log
    )
  }

  @Test("the model catalogue reads the default and filters disabled rows")
  func modelCatalogue() async throws {
    let (client, log) = client { request, _ in
      if request.url.path == "/api/model/default" {
        return Fixtures.json(
          #"{"data":{"modelID":"opus","providerID":"anthropic","name":"Claude Opus 5.5","enabled":true,"status":"active"}}"#
        )
      }
      return Fixtures.json(
        #"{"data":[{"modelID":"opus","providerID":"anthropic","name":"Claude Opus 5.5","enabled":true,"status":"active","capabilities":{"input":["image"]},"limit":{"context":200000},"variants":[{"id":"default"},{"id":"high"}],"canonical":"anthropic"},{"modelID":"off","providerID":"x","name":"Off","enabled":false,"status":"active"}]}"#
      )
    }
    let catalog = try await client.modelCatalog(server, "/work/box")

    #expect(catalog.models.count == 1)
    #expect(catalog.models[0].key == "opus")
    #expect(catalog.models[0].variants == ["high"])
    #expect(catalog.models[0].inputs == ["image"])
    #expect(catalog.defaultModel?.modelID == "opus")
    #expect(log.requests.count == 2)
    #expect(log.requests[0].url.query?.contains("location%5Bdirectory%5D=/work/box") == true)
  }

  @Test("an older server without a default route still returns its models")
  func modelDefaultUnavailable() async throws {
    let (client, _) = client { request, _ in
      if request.url.path == "/api/model/default" {
        return Fixtures.json(#"{"error":"not found"}"#, status: 404)
      }
      return Fixtures.json(
        #"{"data":[{"modelID":"gpt","providerID":"openai","name":"GPT-5.4","enabled":true,"status":"active"}]}"#
      )
    }
    let catalog = try await client.modelCatalog(server, nil)
    #expect(catalog.models.map(\.modelID) == ["gpt"])
    #expect(catalog.defaultModel == nil)
  }

  @Test("model and agent switches post the audited bodies")
  func switches() async throws {
    let (client, log) = client { _, _ in Fixtures.json("{}", status: 204) }
    try await client.switchModel(
      server,
      "s1",
      ModelRef(id: "opus", providerID: "anthropic", variant: "high")
    )
    try await client.switchAgent(server, "s1", "build")

    #expect(log.requests.map(\.method) == ["POST", "POST"])
    #expect(log.requests[0].url.path == "/api/session/s1/model")
    #expect(log.requests[1].url.path == "/api/session/s1/agent")
    let model = try #require(
      try JSONSerialization.jsonObject(with: log.requests[0].body ?? Data()) as? [String: Any]
    )
    #expect((model["model"] as? [String: Any])?["variant"] as? String == "high")
    let agent = try #require(
      try JSONSerialization.jsonObject(with: log.requests[1].body ?? Data()) as? [String: Any]
    )
    #expect(agent["agent"] as? String == "build")
  }

  @Test("agents, skills, commands and file search decode their data envelopes")
  func autocompleteReads() async throws {
    let (client, log) = client { request, _ in
      switch request.url.path {
      case "/api/agent":
        return Fixtures.json(
          #"{"data":[{"id":"build","name":"build","mode":"primary","hidden":false},{"name":"hidden","hidden":true}]}"#
        )
      case "/api/skill":
        return Fixtures.json(#"{"data":[{"id":"review","name":"review","description":"Review"}]}"#)
      case "/api/command":
        return Fixtures.json(#"{"data":[{"name":"init","description":"Create AGENTS.md"}]}"#)
      default:
        return Fixtures.json(#"{"data":["Sources/App.swift"]}"#)
      }
    }
    let agents = try await client.agents(server, "/work/box", true)
    let skills = try await client.skills(server, "/work/box")
    let commands = try await client.commands(server, "/work/box")
    let files = try await client.findFiles(server, "/work/box", "App", 9)

    #expect(agents.map(\.id) == ["build"])
    #expect(skills.map(\.id) == ["review"])
    #expect(commands.map(\.name) == ["init"])
    #expect(files.map(\.path) == ["Sources/App.swift"])
    #expect(files[0].uri.hasPrefix("file:///"))
    #expect(log.requests.last?.url.query?.contains("type=file") == true)
    #expect(log.requests.last?.url.query?.contains("limit=9") == true)
  }
}
