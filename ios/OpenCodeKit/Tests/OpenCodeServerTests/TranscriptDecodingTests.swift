import Foundation
import OpenCodeCore
import OpenCodeServer
import Testing

@Suite("Transcript decoding")
struct TranscriptDecodingTests {
  private let server = OpenCodeServer(
    url: "http://10.0.0.2:4096",
    username: "opencode",
    password: "token"
  )

  private func client(
    _ handler: @escaping @Sendable (HTTPRequest) async throws -> (status: Int, body: Data)
  ) -> (OpenCodeClient, RequestLog) {
    let log = RequestLog()
    let transport = Fixtures.transport(log: log) { request, _ in try await handler(request) }
    return (OpenCodeClient.live(transport: transport, clock: .testValue, policy: .once), log)
  }

  @Test("a user prompt keeps its text, references, quotes and image identity")
  func userPrompt() throws {
    let hash = String(repeating: "a", count: 64)
    let body = """
      {"data":[
        {"id":"m1","type":"user","text":"typed\\nAttached file: `src/App.swift`",
         "metadata":{"attachments":[{"name":"App.swift","mime":"text/plain","path":"src/App.swift"}],
                     "comments":[{"type":"quote","text":"quoted words","comment":"note"}]},
         "files":[{"mime":"image/png","uri":"media:\(hash)","name":"shots/p.png","bytes":123,"width":4,"height":2}]}
      ]}
      """
    let page = try TranscriptDecoder.page(from: Data(body.utf8))
    #expect(page.next == nil)
    #expect(page.items.map(\.id) == ["m1-images", "m1-files", "m1"])

    guard case .userImages(_, let images) = page.items[0] else {
      Issue.record("expected images")
      return
    }
    #expect(images.count == 1)
    #expect(images[0].mediaHash == hash)
    #expect(images[0].aspectRatio == 2)

    guard case .userFiles(_, let files) = page.items[1] else {
      Issue.record("expected files")
      return
    }
    #expect(files.map(\.path) == ["src/App.swift"])

    guard case .userText(_, let text, let source, let quotes) = page.items[2] else {
      Issue.record("expected text")
      return
    }
    #expect(text == "typed")
    #expect(source == nil)
    #expect(quotes == [TranscriptQuote(text: "quoted words", comment: "note")])
  }

  @Test("assistant parts keep REST ordinals and tool identity, and reasoning is not drawn")
  func assistantParts() throws {
    let body = """
      {"data":[
        {"id":"m2","type":"assistant","content":[
          {"type":"reasoning","text":"not shown"},
          {"type":"text","text":"  hello  "},
          {"type":"tool","id":"t1","name":"read",
           "state":{"status":"completed","input":{"path":"x"},"content":[{"type":"text","text":"out"}],"metadata":{}}},
          {"type":"text","text":"   "}
        ]}
      ]}
      """
    let page = try TranscriptDecoder.page(from: Data(body.utf8))
    #expect(page.items.map(\.id) == ["m2-text-0", "m2-tool-t1"])
    guard case .assistantMarkdown(_, let text, let inProgress) = page.items[0] else {
      Issue.record("expected markdown")
      return
    }
    #expect(text == "hello")
    #expect(!inProgress)
    guard case .tool(_, let call) = page.items[1] else {
      Issue.record("expected tool")
      return
    }
    #expect(call.messageID == "m2")
    #expect(call.status == .completed)
    #expect(call.output == ["out"])
    #expect(call.displayName == "Read")
    #expect(call.inputPath == "x")
  }

  @Test("a shell message becomes one completed or failed tool row")
  func shellMessage() throws {
    let body = """
      {"data":[
        {"id":"m3","type":"shell","shellID":"sh1","command":"ls","status":"exited","exit":0,
         "output":{"output":"ok"}},
        {"id":"m4","type":"shell","command":"bad","status":"exited","exit":2,"output":{"output":"no"}}
      ]}
      """
    let page = try TranscriptDecoder.page(from: Data(body.utf8))
    #expect(page.items.map(\.id) == ["m4", "m3"])
    guard case .tool(_, let bad) = page.items[0], case .tool(_, let good) = page.items[1] else {
      Issue.record("expected tools")
      return
    }
    #expect(good.status == .completed)
    #expect(good.shellExit == 0)
    #expect(bad.status == .error)
    #expect(bad.shellExit == 2)
  }

  @Test("messages are returned oldest first regardless of the server's newest-first data")
  func ordering() throws {
    let body = """
      {"data":[{"id":"new","type":"user","text":"new"},{"id":"old","type":"user","text":"old"}],
       "cursor":{"next":"CURSOR"}}
      """
    let page = try TranscriptDecoder.page(from: Data(body.utf8))
    #expect(page.items.map(\.id) == ["old", "new"])
    #expect(page.next == "CURSOR")
  }

  @Test("a failed idle run keeps its error only before a reply, and a failed assistant step keeps its own")
  func runErrors() throws {
    let body = """
      {"data":[
        {"id":"m5","type":"idle","outcome":"failed","error":{"type":"provider.auth","message":"no key"}},
        {"id":"m6","type":"assistant","error":{"type":"tool.execution","message":"boom"}},
        {"id":"m7","type":"idle","outcome":"succeeded"}
      ]}
      """
    let page = try TranscriptDecoder.page(from: Data(body.utf8))
    #expect(page.items.map(\.id) == ["m6-error", "m5"])
    guard case .runError(_, let step) = page.items[0], case .runError(_, let idle) = page.items[1] else {
      Issue.record("expected errors")
      return
    }
    #expect(idle.beforeReply)
    #expect(idle.type == "provider.auth")
    #expect(!step.beforeReply)
    #expect(step.type == "tool.execution")
  }

  @Test("a synthetic notice keeps the typed source and outcome")
  func syntheticNotice() throws {
    let body = """
      {"data":[
        {"id":"n1","type":"synthetic","description":"Explore finished",
         "metadata":{"source":"subagent","state":"completed","agent":"explore"}},
        {"id":"n2","type":"synthetic","description":"Shell failed",
         "metadata":{"source":"shell","state":"completed","exit":1}}
      ]}
      """
    let page = try TranscriptDecoder.page(from: Data(body.utf8))
    guard case .notice(_, _, let shellIsError, _, _) = page.items[0] else {
      Issue.record("expected notice")
      return
    }
    #expect(shellIsError)
    guard case .notice(_, let text, let isError, let kind, let agent) = page.items[1] else {
      Issue.record("expected subagent notice")
      return
    }
    #expect(text == "Explore finished")
    #expect(!isError)
    #expect(kind == TranscriptNoticeKind(source: .subagent, outcome: .finished))
    #expect(agent == "explore")
  }

  @Test("malformed data is a typed undecodable failure, not an empty transcript")
  func malformed() {
    #expect(throws: OpenCodeClientError.self) {
      _ = try TranscriptDecoder.page(from: Data(#"{"data":[{"type":"user"}]}"#.utf8))
    }
    #expect(throws: OpenCodeClientError.self) {
      _ = try TranscriptDecoder.page(from: Data(#"{"nope":true}"#.utf8))
    }
  }

  @Test("tool output and arguments are bounded before entering state")
  func bounds() throws {
    let long = String(repeating: "x", count: 25_000)
    let body = """
      {"data":[{"id":"m8","type":"assistant","content":[
        {"type":"tool","id":"t","name":"write",
         "state":{"status":"completed","input":{"path":"a","body":"\(long)"},
                  "content":[{"type":"text","text":"\(long)"}],"metadata":{}}}
      ]}]}
      """
    let page = try TranscriptDecoder.page(from: Data(body.utf8))
    guard case .tool(_, let call) = page.items[0] else {
      Issue.record("expected tool")
      return
    }
    #expect(call.output[0].utf8.count <= 20_020)
    #expect(call.output[0].hasSuffix("output truncated"))
    if let body = call.input["body"]?.stringValue {
      #expect(body.utf8.count <= 20_020)
    } else {
      Issue.record("expected bounded input")
    }
  }

  @Test("the transcript read sends the newest window query and decodes its cursor")
  func clientTranscriptRoute() async throws {
    let (client, log) = client { _ in
      Fixtures.json(
        #"{"data":[{"id":"m1","type":"user","text":"hi"}],"cursor":{"next":"NEXT"}}"#
      )
    }
    let page = try await client.transcript(server, "s1", 30)
    #expect(page.items.map(\.id) == ["m1"])
    #expect(page.next == "NEXT")
    let url = try #require(log.requests.first?.url)
    let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(query.map(\.name) == ["order", "limit"])
    #expect(query.map { $0.value ?? "" } == ["desc", "30"])
    #expect(url.path == "/api/session/s1/message")
  }

  @Test("history sends a cursor when it has one, otherwise it re-reads the newest window")
  func clientHistoryRoutes() async throws {
    let (client, log) = client { _ in
      Fixtures.json(#"{"data":[],"cursor":{"next":"MORE"}}"#)
    }
    _ = try await client.transcriptHistory(server, "s1", nil)
    _ = try await client.transcriptHistory(server, "s1", "CURSOR")
    let first = try #require(log.requests.first?.url)
    let firstQuery = try #require(URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(firstQuery.map(\.name) == ["limit", "order"])
    #expect(firstQuery.map { $0.value ?? "" } == ["80", "desc"])
    let second = try #require(log.requests.last?.url)
    let secondQuery = try #require(URLComponents(url: second, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(secondQuery.map(\.name) == ["limit", "cursor"])
    #expect(secondQuery.map { $0.value ?? "" } == ["80", "CURSOR"])
  }

  @Test("one message reads its own route")
  func clientMessageRoute() async throws {
    let (client, log) = client { _ in
      Fixtures.json(#"{"data":{"id":"m1","type":"user","text":"hi"}}"#)
    }
    let items = try await client.message(server, "s1", "m1")
    #expect(items.map(\.id) == ["m1"])
    #expect(log.requests.first?.url.path == "/api/session/s1/message/m1")
  }
}
