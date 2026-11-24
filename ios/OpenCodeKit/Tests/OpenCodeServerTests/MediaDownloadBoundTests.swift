import Foundation
import OpenCodeCore
import OpenCodeServer
import OpenCodeTestSupport
import Testing

/// Real loopback downloads through `URLSessionTransport.open`, with small injected bounds so the
/// tests stay tiny while asserting that reception stops near the limit.
@Suite(
  "Media download bounds",
  .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["OPENCODE_SKIP_LOOPBACK_FIXTURES"] == nil)
)
struct MediaDownloadBoundTests {
  private let hash = String(repeating: "a", count: 64)

  private func client(limit: Int64) -> OpenCodeClient {
    let live = URLSessionTransport()
    return OpenCodeClient.live(
      transport: HTTPTransport(send: live.send, open: live.open),
      clock: .testValue,
      policy: .once,
      mediaBlobLimit: limit
    )
  }

  private func server(for fixture: LocalHTTPServer) -> OpenCodeServer {
    OpenCodeServer(url: fixture.baseURL.absoluteString, password: "test")
  }

  @Test("a declared body over the bound is refused before it is collected")
  func declaredOversizedBody() async throws {
    let fixture = try LocalHTTPServer()
    defer { fixture.stop() }
    fixture.route(
      "/api/experimental/media/\(hash)",
      .declared(
        status: 200,
        headers: ["Content-Type": "application/octet-stream"],
        contentLength: 100_000,
        body: Data(repeating: 1, count: 100_000)
      )
    )
    await #expect(throws: OpenCodeClientError.self) {
      _ = try await client(limit: 1_024).mediaBlob(server(for: fixture), hash)
    }
    #expect(await fixture.waitForConnectionClosed(timeout: .seconds(3)))
  }

  @Test("chunked data over the bound stops reception and closes the socket")
  func chunkedOversizedBody() async throws {
    let fixture = try LocalHTTPServer()
    defer { fixture.stop() }
    fixture.route(
      "/api/experimental/media/\(hash)",
      .stream(
        headers: ["Content-Type": "application/octet-stream"],
        chunks: (0..<40).map { _ in Data(repeating: 2, count: 128) },
        intervalMilliseconds: 2
      )
    )
    await #expect(throws: OpenCodeClientError.self) {
      _ = try await client(limit: 1_024).mediaBlob(server(for: fixture), hash)
    }
    #expect(await fixture.waitForConnectionClosed(timeout: .seconds(3)))
  }

  @Test("an understated Content-Length cannot bypass the cumulative bound")
  func understatedContentLength() async throws {
    let transport = HTTPTransport(
      send: { _ in throw TransportError.blocked },
      open: { request in
        let chunks = AsyncThrowingStream<Data, any Error> { continuation in
          for _ in 0..<20 { continuation.yield(Data(repeating: 3, count: 256)) }
          continuation.finish()
        }
        return HTTPStream(
          status: 200,
          headers: ["content-length": "8", "content-type": "application/octet-stream"],
          finalURL: request.url,
          chunks: chunks,
          close: {}
        )
      }
    )
    let client = OpenCodeClient.live(
      transport: transport,
      clock: .testValue,
      policy: .once,
      mediaBlobLimit: 1_024
    )
    await #expect(throws: OpenCodeClientError.self) {
      _ = try await client.mediaBlob(
        OpenCodeServer(url: "https://understated.invalid", password: "test"),
        hash
      )
    }
  }

  @Test("a server file read uses the same cumulative bound")
  func fileReadBound() async throws {
    let fixture = try LocalHTTPServer()
    defer { fixture.stop() }
    fixture.route(
      "/api/fs/read/notes.txt",
      .stream(
        headers: ["Content-Type": "text/plain"],
        chunks: (0..<20).map { _ in Data(repeating: 4, count: 256) },
        intervalMilliseconds: 2
      )
    )
    await #expect(throws: OpenCodeClientError.self) {
      _ = try await client(limit: 25 * 1024 * 1024).readFile(
        server(for: fixture),
        "/work",
        "notes.txt",
        1_024
      )
    }
    #expect(await fixture.waitForConnectionClosed(timeout: .seconds(3)))
  }

  @Test("a body under the bound is returned intact")
  func withinBound() async throws {
    let fixture = try LocalHTTPServer()
    defer { fixture.stop() }
    let body = Data("small body".utf8)
    fixture.route(
      "/api/experimental/media/\(hash)",
      .http(status: 200, headers: ["Content-Type": "application/octet-stream"], body: body)
    )
    let data = try await client(limit: 1_024).mediaBlob(server(for: fixture), hash)
    #expect(data == body)
  }
}
