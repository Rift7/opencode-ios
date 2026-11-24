import Foundation
import OpenCodeCore
import OpenCodeServer
import OpenCodeTestSupport
import Synchronization
import Testing

@Suite("Media client routes")
struct MediaClientTests {
  actor Recorder {
    struct Sent: Sendable, Equatable {
      var path: String
      var query: String
      var method: String
      var authorization: Bool
      var capability: String?
      var accept: String?
    }

    var requests: [Sent] = []
    var uploads: [Sent] = []
    var progress: [Int64] = []

    func record(_ request: HTTPRequest) {
      requests.append(
        Sent(
          path: request.url.path,
          query: request.url.query ?? "",
          method: request.method,
          authorization: request.authorization != nil,
          capability: request.headers["X-OpenCode-Capabilities"],
          accept: request.headers["Accept"]
        )
      )
    }

    func recordUpload(_ request: HTTPRequest) {
      uploads.append(
        Sent(
          path: request.url.path,
          query: request.url.query ?? "",
          method: request.method,
          authorization: request.authorization != nil,
          capability: request.headers["X-OpenCode-Capabilities"],
          accept: request.headers["Accept"]
        )
      )
    }

    func recordProgress(_ sent: Int64) { progress.append(sent) }
  }

  func server() -> OpenCodeServer {
    OpenCodeServer(url: "https://wire-00000000-0000-4000-8000-000000000000.invalid", password: "test")
  }

  func transport(
    recorder: Recorder,
    info: ServerInfo,
    blob: Data = Data([1, 2, 3]),
    uploadPath: String = "/tmp/uploads/x/report.pdf"
  ) -> HTTPTransport {
    HTTPTransport(
      send: { request in
        await recorder.record(request)
        switch request.url.path {
        case "/api/info":
          return HTTPResponse(
            status: 200,
            headers: ["content-type": "application/json"],
            body: try JSONEncoder().encode(info),
            finalURL: request.url
          )
        case "/api/experimental/media/\(request.url.lastPathComponent)":
          return HTTPResponse(
            status: 200,
            headers: ["content-type": "application/octet-stream"],
            body: blob,
            finalURL: request.url
          )
        case let path where path.hasPrefix("/api/fs/read/"):
          return HTTPResponse(
            status: 200,
            headers: ["content-type": "text/plain"],
            body: Data("let value = 1\n".utf8),
            finalURL: request.url
          )
        case "/api/fs/list":
          return HTTPResponse(
            status: 200,
            headers: ["content-type": "application/json"],
            body: Data(#"{"location":{"directory":"/work/app"},"data":[{"path":"src","type":"directory"}]}"#.utf8),
            finalURL: request.url
          )
        default:
          return HTTPResponse(status: 404, headers: [:], body: Data(), finalURL: request.url)
        }
      },
      open: { _ in throw TransportError.blocked },
      upload: { request, _, progress in
        await recorder.recordUpload(request)
        progress(4)
        await recorder.recordProgress(4)
        return HTTPResponse(
          status: 200,
          headers: ["content-type": "application/json"],
          body: Data(#"{"data":{"path":"\#(uploadPath)"}}"#.utf8),
          finalURL: request.url
        )
      }
    )
  }

  @Test("a media blob is read with the capability header and this server's credentials")
  func mediaBlobRequest() async throws {
    let recorder = Recorder()
    let hash = String(repeating: "a", count: 64)
    let client = OpenCodeClient.live(
      transport: transport(recorder: recorder, info: ServerInfo(version: "1", pid: 1)),
      clock: .testValue,
      policy: .once
    )
    let data = try await client.mediaBlob(server(), hash)
    #expect(data == Data([1, 2, 3]))
    let sent = await recorder.requests
    #expect(sent.first?.path == "/api/experimental/media/\(hash)")
    #expect(sent.first?.authorization == true)
    #expect(sent.first?.capability == "experimental-media-uri")
    #expect(sent.first?.accept == "*/*")
  }

  @Test("an upload discovers paths.tmp, keeps one path and reports progress")
  func uploadRequest() async throws {
    let environment = IsolatedTestEnvironment(testName: "media-upload-route")
    defer { environment.cleanUp() }
    let file = environment.root.appendingPathComponent("report.pdf")
    try Data("pdf".utf8).write(to: file)
    let recorder = Recorder()
    let info = ServerInfo(version: "1", pid: 1, paths: ServerInfo.Paths(tmp: "/tmp"))
    let client = OpenCodeClient.live(
      transport: transport(recorder: recorder, info: info),
      clock: .testValue,
      policy: .once
    )
    let reported = Mutex<[Int64]>([])
    let path = try await client.uploadFile(server(), "/work/app", file, "report.pdf") { sent in
      reported.withLock { $0.append(sent) }
    }
    #expect(path == "/tmp/uploads/x/report.pdf")
    #expect(reported.withLock { $0 } == [4])
    let uploads = await recorder.uploads
    #expect(uploads.count == 1)
    #expect(uploads.first?.method == "POST")
    #expect(uploads.first?.authorization == true)
    let query = try #require(uploads.first?.query.removingPercentEncoding)
    #expect(query.contains("path=/tmp/uploads/"))
    #expect(query.contains("location[directory]=/work/app"))
  }

  @Test("a server without paths.tmp reports uploads as unsupported")
  func uploadUnsupported() async throws {
    let environment = IsolatedTestEnvironment(testName: "media-upload-unsupported")
    defer { environment.cleanUp() }
    let file = environment.root.appendingPathComponent("report.pdf")
    try Data("pdf".utf8).write(to: file)
    let client = OpenCodeClient.live(
      transport: transport(recorder: Recorder(), info: ServerInfo(version: "1", pid: 1)),
      clock: .testValue,
      policy: .once
    )
    await #expect(throws: OpenCodeClientError.self) {
      _ = try await client.uploadFile(server(), nil, file, "report.pdf") { _ in }
    }
  }

  @Test("a server file read is scoped by location and bounded before it reaches the viewer")
  func fileReadAndListing() async throws {
    let recorder = Recorder()
    let client = OpenCodeClient.live(
      transport: transport(recorder: recorder, info: ServerInfo(version: "1", pid: 1)),
      clock: .testValue,
      policy: .once
    )
    let data = try await client.readFile(server(), "/work/app", "Sources/main.swift", 100)
    #expect(String(decoding: data, as: UTF8.self) == "let value = 1\n")
    let sent = await recorder.requests
    let read = try #require(sent.first { $0.path.hasPrefix("/api/fs/read/") })
    #expect(read.query.removingPercentEncoding?.contains("location[directory]=/work/app") == true)
    #expect(read.capability == "experimental-media-uri")

    let listing = try await client.listDirectory(server(), nil)
    #expect(listing.directory == "/work/app")
    #expect(listing.entries.first?.path == "src")
    #expect(listing.entries.first?.isDirectory == true)
  }
}
