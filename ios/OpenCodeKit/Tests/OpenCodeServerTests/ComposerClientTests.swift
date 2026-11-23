import Foundation
import OpenCodeCore
import OpenCodeServer
import Testing

@Suite("Composer client routes")
struct ComposerClientTests {
  private let server = OpenCodeServer(
    url: "http://10.0.0.2:4096",
    username: "opencode",
    password: "token"
  )

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

  @Test("a prompt posts the id, text, delivery and quote metadata")
  func promptShape() async throws {
    let (client, log) = client { _, _ in (204, Data()) }
    let prompt = PromptBody(
      id: "message-1",
      text: "typed\n\nThe user quoted the following from earlier in the conversation:\n> line",
      delivery: .queue,
      metadata: PromptBody.Metadata(
        displayText: "typed",
        comments: [.init(type: "quote", text: "line", comment: "note")]
      )
    )
    try await client.sendPrompt(server, "session-1", prompt)

    let request = try #require(log.requests.first)
    #expect(request.method == "POST")
    #expect(request.url.path == "/api/session/session-1/prompt")
    let body = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
    #expect(body?["id"] as? String == "message-1")
    #expect(body?["delivery"] as? String == "queue")
    let metadata = body?["metadata"] as? [String: Any]
    #expect(metadata?["displayText"] as? String == "typed")
    let comments = metadata?["comments"] as? [[String: Any]]
    #expect(comments?.first?["type"] as? String == "quote")
    #expect(comments?.first?["text"] as? String == "line")
    #expect(comments?.first?["comment"] as? String == "note")
  }

  @Test("a session create posts the client id and location and decodes the session")
  func createShape() async throws {
    let (client, log) = client { _, _ in
      Fixtures.json(
        #"{"data":{"id":"new-id","projectID":"p1","time":{"updated":1750000000000},"location":{"directory":"/work/box"},"title":"New"}}"#
      )
    }
    let session = try await client.createSession(server, "/work/box", "new-id")
    #expect(session.id == "new-id")
    #expect(session.directory == "/work/box")
    let request = try #require(log.requests.first)
    #expect(request.method == "POST")
    #expect(request.url.path == "/api/session")
    let body = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
    #expect(body?["id"] as? String == "new-id")
    let location = body?["location"] as? [String: Any]
    #expect(location?["directory"] as? String == "/work/box")
  }

  @Test("cancelling an inbox input uses DELETE and is idempotent")
  func cancelInputShape() async throws {
    let (client, log) = client { _, _ in (204, Data()) }
    try await client.cancelPendingInput(server, "session-1", "input-1")
    let request = try #require(log.requests.first)
    #expect(request.method == "DELETE")
    #expect(request.url.path == "/api/session/session-1/inbox/input-1")
  }

  @Test("wait for idle uses the experimental route and its own single retry layer")
  func waitRoute() async throws {
    let (client, log) = client { request, _ in
      if request.url.path.hasSuffix("/wait") { return (200, Data()) }
      return Fixtures.json(#"{"data":{}}"#)
    }
    try await client.waitForIdle(server, "session-1")
    let request = try #require(log.requests.first)
    #expect(request.method == "POST")
    #expect(request.url.path == "/api/experimental/session/session-1/wait")
  }
}
