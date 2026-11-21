import Foundation
import OpenCodeCore
import OpenCodeTestSupport
import Testing

/// Each test owns a unique host, because `NetworkGuard` answers every suite in the process and a
/// registration is never reset underneath another test.
@Suite("URLSession transport", .serialized)
struct URLSessionTransportTests {
  private func transport() -> URLSessionTransport {
    URLSessionTransport(configuration: {
      let configuration = URLSessionTransport.ephemeralConfiguration()
      configuration.protocolClasses = [NetworkGuard.self]
      return configuration
    })
  }

  private func records(for host: String) -> [NetworkGuard.RecordedRequest] {
    NetworkGuard.recordedRequests.filter { $0.host == host }
  }

  @Test("a request carries its method, path and headers")
  func requestConstruction() async throws {
    let host = "construct.local"
    NetworkGuard.register(host: host, fixture: .init(body: Data(#"{"ok":true}"#.utf8)))

    let request = HTTPRequest(
      url: try #require(URL(string: "http://\(host)/api/session?limit=50")),
      method: "GET",
      headers: ["Accept": "application/json", "X-OpenCode-Op": "OP-1"],
      authorization: "Basic c2VjcmV0",
      timeout: 5
    )
    let response = try await transport().send(request)

    #expect(response.status == 200)
    #expect(response.body == Data(#"{"ok":true}"#.utf8))
    let recorded = try #require(records(for: host).first)
    #expect(recorded.method == "GET")
    #expect(recorded.path == "/api/session?limit=50")
    #expect(recorded.headers["accept"] == "application/json")
    #expect(recorded.headers["x-opencode-op"] == "OP-1")
    #expect(recorded.headers["authorization"] == "Basic c2VjcmV0")
  }

  @Test("a 401 is a response, not a transport failure")
  func unauthorizedIsAResponse() async throws {
    let host = "unauthorized.local"
    NetworkGuard.register(host: host, fixture: .init(statusCode: 401, body: Data(#"{"error":"x"}"#.utf8)))

    let response = try await transport().send(
      HTTPRequest(url: try #require(URL(string: "https://\(host)/api/info")))
    )
    #expect(response.status == 401)
    #expect(response.header("content-type") == "application/json")
  }

  @Test("a redirect policy that rejects hands the 3xx back")
  func rejectPolicyReturnsTheRedirect() async throws {
    let host = "reject.local"
    NetworkGuard.register(host: host, fixture: .init(
      statusCode: 302,
      headers: ["Location": "http://\(host)/moved"]
    ))

    let response = try await transport().send(
      HTTPRequest(
        url: try #require(URL(string: "http://\(host)/auth/connect/code")),
        redirectPolicy: .reject
      )
    )
    #expect(response.status == 302)
    #expect(records(for: host).count == 1)
  }

  @Test("plain HTTP to a public host is refused before anything is sent")
  func refusesPublicCleartext() async throws {
    await #expect(throws: TransportError.insecureHTTP) {
      _ = try await transport().send(
        HTTPRequest(url: try #require(URL(string: "http://example.com/api/info")))
      )
    }
    #expect(records(for: "example.com").isEmpty)
  }

  @Test("a stream delivers fragmented chunks in order")
  func streamsFragments() async throws {
    let host = "stream.local"
    let body = Data("data: {\"type\":\"server.connected\"}\n\n".utf8)
    var chunks: [Data] = []
    var offset = 0
    while offset < body.count {
      let end = min(offset + 5, body.count)
      chunks.append(body.subdata(in: offset..<end))
      offset = end
    }
    NetworkGuard.register(host: host, fixture: .init(
      headers: ["Content-Type": "text/event-stream"],
      body: body,
      chunks: chunks
    ))

    let stream = try await transport().open(
      HTTPRequest(
        url: try #require(URL(string: "http://\(host)/api/event")),
        headers: ["Accept": "text/event-stream"]
      )
    )
    #expect(stream.status == 200)
    #expect(stream.header("content-type") == "text/event-stream")

    var received = Data()
    for try await chunk in stream.chunks {
      received.append(chunk)
    }
    #expect(received == body)
    let recorded = try #require(records(for: host).first)
    #expect(recorded.headers["accept"] == "text/event-stream")
  }

  @Test("a stream ends when the reader stops")
  func streamCancellationEndsTheRead() async throws {
    let host = "cancel-stream.local"
    NetworkGuard.register(host: host, fixture: .init(
      body: Data(),
      chunks: [Data("one".utf8), Data("two".utf8)]
    ))

    let stream = try await transport().open(
      HTTPRequest(url: try #require(URL(string: "http://\(host)/api/event")))
    )
    var count = 0
    for try await _ in stream.chunks {
      count += 1
      if count == 1 { break }
    }
    #expect(count == 1)
  }
}
