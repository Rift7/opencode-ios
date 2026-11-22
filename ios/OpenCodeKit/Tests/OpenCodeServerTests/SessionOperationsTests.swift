import Foundation
import OpenCodeCore
import OpenCodeServer
import Testing

@Suite("Session operations")
struct SessionOperationsTests {
  private let server = OpenCodeServer(
    url: "http://127.0.0.1:4110",
    username: "opencode",
    password: "test-token"
  )

  private func jsonBody(_ request: HTTPRequest) -> [String: Any] {
    guard let data = request.body,
      let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return value
  }

  @Test("interrupt sends resume=true once and decodes interrupted")
  func interrupt() async throws {
    let log = RequestLog()
    let transport = Fixtures.transport(log: log) { _, _ in
      Fixtures.json(#"{"interrupted":true}"#)
    }
    let client = OpenCodeClient.live(transport: transport, clock: .testValue)

    #expect(try await client.interruptSession(server, "s1"))
    let request = try #require(log.requests.last)
    #expect(request.method == "POST")
    #expect(request.url.path == "/api/session/s1/interrupt")
    #expect(request.url.query?.contains("resume=true") == true)
  }

  @Test("a permission denial carries its reason; allowance does not")
  func permissionReply() async throws {
    let log = RequestLog()
    let transport = Fixtures.transport(log: log) { _, _ in Fixtures.json("{}") }
    let client = OpenCodeClient.live(transport: transport, clock: .testValue)

    try await client.replyPermission(server, "s1", "r1", .reject, " use make ")
    var body = jsonBody(try #require(log.requests.last))
    #expect(body["decision"] as? String == "reject")
    #expect(body["message"] as? String == "use make")

    try await client.replyPermission(server, "s1", "r1", .once, "ignored")
    body = jsonBody(try #require(log.requests.last))
    #expect(body["decision"] as? String == "once")
    #expect(body["message"] == nil)
  }

  @Test("a global form reply includes the location directory and only its answers")
  func globalFormReply() async throws {
    let log = RequestLog()
    let transport = Fixtures.transport(log: log) { _, _ in Fixtures.json("{}") }
    let client = OpenCodeClient.live(transport: transport, clock: .testValue)

    let outcome = try await client.replyForm(
      server,
      "global",
      "f1",
      ["name": .string("Ada"), "count": .number(2)],
      "/work/opencode"
    )
    #expect(outcome == .settled)
    let request = try #require(log.requests.last)
    #expect(request.url.path == "/api/session/global/form/f1/reply")
    #expect(request.url.query?.contains("location%5Bdirectory%5D=/work/opencode") == true)
    let answer = jsonBody(request)["answer"] as? [String: Any]
    #expect(answer?["name"] as? String == "Ada")
    #expect(answer?["count"] as? Double == 2)
  }

  @Test("shell output carries absolute cursors and the location")
  func shellOutput() async throws {
    let log = RequestLog()
    let transport = Fixtures.transport(log: log) { _, _ in
      Fixtures.json(#"{"data":{"output":"ok","cursor":2,"size":2}}"#)
    }
    let client = OpenCodeClient.live(transport: transport, clock: .testValue)

    let page = try await client.shellOutput(server, "/work/box", "sh1", 0, 65_536)
    #expect(page == ShellOutputPage(output: "ok", cursor: 2, size: 2))
    let query = try #require(log.requests.last?.url.query)
    #expect(query.contains("cursor=0"))
    #expect(query.contains("limit=65536"))
    #expect(query.contains("location%5Bdirectory%5D=/work/box"))
  }
}
