import Foundation
import OpenCodeCore
import OpenCodeTestSupport
import Synchronization
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

  @Test("requests share one session for the transport's lifetime")
  func requestsShareOneSession() async throws {
    let host = "shared-session.local"
    NetworkGuard.register(host: host, fixture: .init(body: Data("[]".utf8)))
    let sessions = SessionCounter()
    let transport = URLSessionTransport(configuration: {
      sessions.increment()
      let configuration = URLSessionTransport.ephemeralConfiguration()
      configuration.protocolClasses = [NetworkGuard.self]
      return configuration
    })
    let url = try #require(URL(string: "https://\(host)/api/project"))

    _ = try await transport.send(HTTPRequest(url: url))
    _ = try await transport.send(HTTPRequest(url: url))

    #expect(sessions.value == 1)
  }

  @Test("each stream owns its own session")
  func eachStreamOwnsASession() async throws {
    let host = "stream-sessions.local"
    NetworkGuard.register(host: host, fixture: .init(body: Data(), chunks: [Data("a".utf8)]))
    let sessions = SessionCounter()
    let transport = URLSessionTransport(configuration: {
      sessions.increment()
      let configuration = URLSessionTransport.ephemeralConfiguration()
      configuration.protocolClasses = [NetworkGuard.self]
      return configuration
    })
    let url = try #require(URL(string: "https://\(host)/api/event"))

    for _ in 0..<2 {
      let stream = try await transport.open(HTTPRequest(url: url))
      for try await _ in stream.chunks {}
    }

    #expect(sessions.value == 2)
  }

  @Test("an open cancelled before it starts throws cancellation")
  func preCancelledOpen() async throws {
    let host = "pre-cancelled.local"
    NetworkGuard.register(host: host, fixture: .init(body: Data()))
    let transport = transport()
    let url = try #require(URL(string: "https://\(host)/api/event"))

    let task = Task { () -> HTTPStream in
      withUnsafeCurrentTask { $0?.cancel() }
      return try await transport.open(HTTPRequest(url: url))
    }
    let result = await task.result
    #expect(throws: CancellationError.self) { try result.get() }
  }

  @Test("an open cancelled during startup throws cancellation instead of hanging")
  func cancelledDuringStartup() async throws {
    let host = "startup-cancelled.local"
    NetworkGuard.register(host: host, fixture: .init(body: Data()))
    let transport = URLSessionTransport(configuration: {
      // Cancels the calling task at the one point that is otherwise hard to hit: between
      // checking cancellation and registering the startup continuation.
      withUnsafeCurrentTask { $0?.cancel() }
      let configuration = URLSessionTransport.ephemeralConfiguration()
      configuration.protocolClasses = [NetworkGuard.self]
      return configuration
    })
    let url = try #require(URL(string: "https://\(host)/api/event"))

    let task = Task { try await transport.open(HTTPRequest(url: url)) }
    let result = await task.result
    #expect(throws: CancellationError.self) { try result.get() }
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


/// Counts how many `URLSession` instances a transport configured.
private final class SessionCounter: Sendable {
  private let state = Mutex(0)

  var value: Int { state.withLock { $0 } }

  func increment() { state.withLock { $0 += 1 } }
}
