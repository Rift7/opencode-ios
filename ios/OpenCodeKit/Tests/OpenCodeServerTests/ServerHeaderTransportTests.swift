import Foundation
import OpenCodeCore
import OpenCodeServer
import Testing

@Suite("Custom headers at the request boundary")
struct ServerHeaderTransportTests {
  private func server(headers: [OpenCodeServer.Header]) -> OpenCodeServer {
    OpenCodeServer(
      url: "http://10.0.0.2:4096",
      username: "opencode",
      password: "token",
      headers: headers
    )
  }

  private func client() -> (OpenCodeClient, RequestLog) {
    let log = RequestLog()
    return (
      OpenCodeClient.live(
        transport: Fixtures.transport(log: log) { _, _ in
          Fixtures.json(#"[]"#)
        },
        clock: .testValue,
        policy: .once
      ),
      log
    )
  }

  @Test("an edited header reaches the request and a removed one does not")
  func updateAndRemove() async throws {
    let (client, log) = client()
    let withHeader = server(headers: [
      .init(name: "CF-Access-Client-Id", value: "synthetic-id"),
      .init(name: "CF-Access-Client-Secret", value: "synthetic-secret"),
    ])
    _ = try await client.projects(withHeader)
    #expect(log.requests[0].headers["CF-Access-Client-Id"] == "synthetic-id")
    #expect(log.requests[0].headers["CF-Access-Client-Secret"] == "synthetic-secret")
    #expect(log.requests[0].authorization?.hasPrefix("Basic ") == true)

    let removed = server(headers: [])
    _ = try await client.projects(removed)
    #expect(log.requests[1].headers["CF-Access-Client-Id"] == nil)
    #expect(log.requests[1].headers["CF-Access-Client-Secret"] == nil)
    #expect(log.requests[1].authorization?.hasPrefix("Basic ") == true)
  }

  @Test("a forbidden or malformed saved header is skipped without locking out the server")
  func invalidSavedHeaderIsSkipped() async throws {
    let (client, log) = client()
    let invalid = server(headers: [
      .init(name: "Host", value: "elsewhere.invalid"),
      .init(name: "X-Good", value: "kept"),
      .init(name: "X-Bad", value: "line\r\nbreak"),
    ])
    _ = try await client.projects(invalid)
    #expect(log.requests[0].headers["Host"] == nil)
    #expect(log.requests[0].headers["X-Bad"] == nil)
    #expect(log.requests[0].headers["X-Good"] == "kept")
    #expect(log.requests[0].authorization?.hasPrefix("Basic ") == true)
  }
}
