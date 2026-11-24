import ComposableArchitecture
import CoreGraphics
import Foundation
import ImageIO
import OpenCodeCore
import OpenCodeMedia
import OpenCodeServer
import OpenCodeTestSupport
import Testing
import UniformTypeIdentifiers

private func testImageData(width: Int = 640, height: Int = 480, format: UTType = .png) -> Data {
  let space = CGColorSpaceCreateDeviceRGB()
  guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ) else { return Data() }
  context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  context.setFillColor(red: 1, green: 0.8, blue: 0.2, alpha: 1)
  context.fill(CGRect(x: 20, y: 20, width: width / 3, height: height / 3))
  guard let image = context.makeImage() else { return Data() }
  let data = NSMutableData()
  guard let destination = CGImageDestinationCreateWithData(data, format.identifier as CFString, 1, nil)
  else { return Data() }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { return Data() }
  return data as Data
}

private func fixtureServer() -> OpenCodeServer {
  OpenCodeServer(url: "https://\(InertFixtures.fixtureHost)", password: "test")
}

@Suite("Media import")
struct MediaImportTests {
  @Test("a picked image is re-encoded as a bounded JPEG and staged")
  func imageImportReencodesAndBounds() async throws {
    let environment = IsolatedTestEnvironment(testName: "media-image-import")
    defer { environment.cleanUp() }
    let root = try environment.directory("stage")
    let store = MediaFileStore(root: root)
    let importer = MediaImportClient.live(store: store)
    let attachment = try await importer.importImage(testImageData(), "server-one", "a1")
    #expect(attachment.kind == .image)
    #expect(attachment.mime == "image/jpeg")
    #expect(attachment.pixelWidth == 640)
    #expect(attachment.pixelHeight == 480)
    #expect(attachment.transfer == .inline)
    let url = await store.url(serverID: "server-one", storedName: attachment.storedName)
    #expect(FileManager.default.fileExists(atPath: url.path))
    let bytes = try Data(contentsOf: url)
    #expect(bytes.prefix(2) == Data([0xFF, 0xD8]))
  }

  @Test("an image larger than 1568 pixels is downscaled, never upscaled")
  func imageIsDownscaled() async throws {
    let environment = IsolatedTestEnvironment(testName: "media-image-downscale")
    defer { environment.cleanUp() }
    let store = MediaFileStore(root: try environment.directory("stage"))
    let importer = MediaImportClient.live(store: store)
    let attachment = try await importer.importImage(testImageData(width: 4_000, height: 2_000), "s", "a")
    #expect(attachment.pixelWidth == 1_568)
    #expect(attachment.pixelHeight == 784)
  }

  @Test("an oversized source image is refused without writing")
  func oversizedImageIsRefused() async throws {
    let environment = IsolatedTestEnvironment(testName: "media-image-oversized")
    defer { environment.cleanUp() }
    let store = MediaFileStore(root: try environment.directory("stage"))
    let importer = MediaImportClient.live(store: store)
    let data = Data(count: Int(MediaLimits.maximumImageSourceBytes + 1))
    await #expect(throws: MediaAttachmentProblem.tooLarge) {
      _ = try await importer.importImage(data, "s", "a")
    }
  }

  @Test("corrupt image bytes are refused as unsupported")
  func corruptImageIsRefused() async throws {
    let environment = IsolatedTestEnvironment(testName: "media-image-corrupt")
    defer { environment.cleanUp() }
    let store = MediaFileStore(root: try environment.directory("stage"))
    let importer = MediaImportClient.live(store: store)
    await #expect(throws: MediaAttachmentProblem.unsupported) {
      _ = try await importer.importImage(Data("not an image".utf8), "s", "a")
    }
  }

  @Test("a text file is staged for upload and labelled text/plain")
  func textFileSniffsAsText() async throws {
    let environment = IsolatedTestEnvironment(testName: "media-file-text")
    defer { environment.cleanUp() }
    let store = MediaFileStore(root: try environment.directory("stage"))
    let importer = MediaImportClient.live(store: store)
    let source = environment.root.appendingPathComponent("notes.md")
    try Data("# Notes\n\nHello".utf8).write(to: source)
    let attachment = try await importer.importFile(source, "notes.md", "s", "f1")
    #expect(attachment.kind == .file)
    #expect(attachment.mime == "text/plain")
    #expect(attachment.transfer == .uploading(sent: 0))
    #expect(attachment.byteCount == 14)
  }

  @Test("an oversized file is refused and leaves no staging folder")
  func oversizedFileLeavesNoPartial() async throws {
    let environment = IsolatedTestEnvironment(testName: "media-file-oversized")
    defer { environment.cleanUp() }
    let store = MediaFileStore(root: try environment.directory("stage"))
    let source = environment.root.appendingPathComponent("huge.bin")
    try Data(count: 32).write(to: source)
    await #expect(throws: MediaAttachmentProblem.tooLarge) {
      _ = try await store.copyFile(
        at: source,
        name: "huge.bin",
        serverID: "s",
        id: "big",
        maximumBytes: 16
      )
    }
    let folder = store.serverDirectory("s").appendingPathComponent("big")
    #expect(!FileManager.default.fileExists(atPath: folder.path))
  }

  @Test("a long paste keeps its text and normalises line endings")
  func pastedTextIsStaged() async throws {
    let environment = IsolatedTestEnvironment(testName: "media-paste")
    defer { environment.cleanUp() }
    let store = MediaFileStore(root: try environment.directory("stage"))
    let importer = MediaImportClient.live(store: store)
    let text = Array(repeating: "line", count: 20).joined(separator: "\r\n")
    let attachment = try await importer.importPastedText(text, "s", "p1")
    #expect(attachment.kind == .pastedText)
    #expect(attachment.mime == "text/plain")
    let data = try await store.read(serverID: "s", storedName: attachment.storedName, maximumBytes: 1_000)
    #expect(String(decoding: data, as: UTF8.self) == text.replacingOccurrences(of: "\r\n", with: "\n"))
  }

  @Test("only more than twelve lines or a thousand characters is a long paste")
  func longPasteThreshold() {
    #expect(!MediaLimits.isLongPaste("ordinary typing"))
    #expect(!MediaLimits.isLongPaste(Array(repeating: "a", count: 12).joined(separator: "\n")))
    #expect(MediaLimits.isLongPaste(Array(repeating: "a", count: 13).joined(separator: "\n")))
    #expect(MediaLimits.isLongPaste(String(repeating: "a", count: 1_001)))
  }
}

@Suite("Attachment ownership and paths")
struct MediaAttachmentTests {
  @Test("an attachment round-trips through Codable with its upload state")
  func attachmentRoundTrip() throws {
    let attachment = MediaAttachment(
      id: "a",
      kind: .file,
      name: "report.pdf",
      mime: "application/pdf",
      byteCount: 42,
      storedName: "a/report.pdf",
      transfer: .uploaded(path: "/tmp/uploads/a/report.pdf")
    )
    let data = try JSONEncoder().encode(attachment)
    let decoded = try JSONDecoder().decode(MediaAttachment.self, from: data)
    #expect(decoded == attachment)
    #expect(decoded.fileReference?.path == "/tmp/uploads/a/report.pdf")
  }

  @Test("a server path resolves to a location and relative path, never a local URL")
  func serverPathTarget() {
    let inside = AgentFilePath.target(path: "/work/app/main.swift", directory: "/work/app")
    #expect(inside?.location == "/work/app")
    #expect(inside?.relativePath == "main.swift")
    let outside = AgentFilePath.target(path: "/tmp/log.txt", directory: "/work/app")
    #expect(outside?.location == "/tmp")
    #expect(outside?.relativePath == "log.txt")
    let relative = AgentFilePath.target(path: "notes/today.md", directory: "/work/app")
    #expect(relative?.location == "/work/app")
    #expect(relative?.relativePath == "notes/today.md")
    #expect(AgentFilePath.target(path: "/work/app/../../etc/passwd", directory: "/work/app")?.relativePath == "passwd")
    #expect(AgentFilePath.target(path: "/", directory: "/work/app") == nil)
  }

  @Test("a media hash is only accepted in its 64-hex form")
  func mediaHashValidation() {
    #expect(MediaReference.isValidHash(String(repeating: "a", count: 64)))
    #expect(!MediaReference.isValidHash(String(repeating: "a", count: 63)))
    #expect(!MediaReference.isValidHash(String(repeating: "g", count: 64)))
    #expect(MediaReference.hash("media:\(String(repeating: "b", count: 64))") != nil)
  }

  @Test("an abandoned staging folder is removed only when no record names it")
  func abandonedCleanup() async throws {
    let environment = IsolatedTestEnvironment(testName: "media-cleanup")
    defer { environment.cleanUp() }
    let store = MediaFileStore(root: try environment.directory("stage"))
    _ = try await store.write(Data("a".utf8), name: "a.txt", serverID: "s", id: "keep")
    _ = try await store.write(Data("b".utf8), name: "b.txt", serverID: "s", id: "drop")
    await store.cleanupAbandonedFiles(serverID: "s", keeping: ["keep/a.txt"])
    let directory = store.serverDirectory("s")
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("keep/a.txt").path))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("drop/b.txt").path))
  }
}

@Suite("Media references")
struct MediaReferenceCacheTests {
  @Test("a load coalesces, survives a memory purge on disk, and remembers a 404 per server")
  func cacheLoadAndEviction() async throws {
    let environment = IsolatedTestEnvironment(testName: "media-reference-cache")
    defer { environment.cleanUp() }
    let directory = try environment.directory("blobs")
    let counter = Counter()
    let server = fixtureServer()
    let cache = MediaReferenceCache(directory: directory) { server, hash in
      await counter.increment()
      if hash.hasPrefix("f") { throw OpenCodeClientError(.status(404)) }
      return Data("image-bytes".utf8)
    }
    let hash = String(repeating: "a", count: 64)
    let first = await cache.load(server: server, hash: hash)
    #expect(first == .loaded(Data("image-bytes".utf8)))
    await cache.purgeMemory()
    let second = await cache.load(server: server, hash: hash)
    #expect(second == .loaded(Data("image-bytes".utf8)))
    #expect(await counter.value == 1)
    let missing = String(repeating: "f", count: 64)
    #expect(await cache.load(server: server, hash: missing) == .unavailable)
    #expect(await cache.load(server: server, hash: missing) == .unavailable)
  }

  @Test("trimming counts finished blobs only, keeps a partial, and deletes the oldest first")
  func diskTrim() async throws {
    let environment = IsolatedTestEnvironment(testName: "media-reference-trim")
    defer { environment.cleanUp() }
    let directory = try environment.directory("blobs")
    let cache = MediaReferenceCache(
      directory: directory,
      bounds: MediaReferenceCache.Bounds(memoryBytes: 100, memoryEntries: 2, diskBytes: 20, blobBytes: 100)
    ) { _, _ in throw OpenCodeClientError(.status(500)) }
    for (name, age) in [("a", 300.0), ("b", 200.0), ("c", 100.0)] {
      let url = directory.appendingPathComponent("\(name).blob")
      try Data(repeating: 0, count: 10).write(to: url)
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 - age)],
        ofItemAtPath: url.path
      )
    }
    let partial = directory.appendingPathComponent("d.partial")
    try Data(repeating: 0, count: 100).write(to: partial)
    await cache.trim()
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("a.blob").path))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("c.blob").path))
    #expect(FileManager.default.fileExists(atPath: partial.path))
  }
}

private actor Counter {
  private(set) var value = 0
  func increment() { value += 1 }
}

@Suite("Browser policy")
struct BrowserPolicyTests {
  @Test("public pages are accepted and local, signed or credentialed ones are not")
  func publicPages() {
    #expect(BrowserLinkPolicy.isPublicWebPage("https://example.com/docs"))
    #expect(!BrowserLinkPolicy.isPublicWebPage("http://mac.local:4096"))
    #expect(!BrowserLinkPolicy.isPublicWebPage("http://127.0.0.1:4110"))
    #expect(!BrowserLinkPolicy.isPublicWebPage("https://user:pass@example.com/a"))
    #expect(!BrowserLinkPolicy.isPublicWebPage("https://example.com/a?token=secret"))
    #expect(!BrowserLinkPolicy.isPublicWebPage("https://1.2.3.4/a"))
    #expect(!BrowserLinkPolicy.isPublicWebPage("opencode://pair?code=abc"))
    #expect(BrowserLinkPolicy.isPublicWebPage("http://127.0.0.1:4110", allowsLoopback: true))
  }

  @Test("the experiment gate decides whether a public link opens in place")
  func routing() {
    #expect(BrowserLinkPolicy.route(url: "https://example.com/a", inAppBrowser: false) == .system("https://example.com/a"))
    #expect(BrowserLinkPolicy.route(url: "https://example.com/a", inAppBrowser: true) == .inAppBrowser("https://example.com/a"))
    #expect(BrowserLinkPolicy.route(url: "http://10.0.0.2/a", inAppBrowser: true) == .system("http://10.0.0.2/a"))
  }

  @Test("page navigations allow public pages and hand user taps for other schemes to the system")
  func navigation() {
    #expect(BrowserNavigationPolicy.decide(url: "https://example.com", isMainFrame: true, isUserTap: false) == .allow)
    #expect(
      BrowserNavigationPolicy.decide(url: "mailto:hi@example.com", isMainFrame: true, isUserTap: true)
        == .openInSystem("mailto:hi@example.com")
    )
    #expect(
      BrowserNavigationPolicy.decide(url: "mailto:hi@example.com", isMainFrame: false, isUserTap: false)
        == .cancel
    )
    #expect(
      BrowserNavigationPolicy.decide(url: "opencode-ios://pair?code=abc", isMainFrame: true, isUserTap: true)
        == .pair("opencode-ios://pair?code=abc")
    )
    #expect(BrowserNavigationPolicy.decide(url: "about:blank", isMainFrame: true, isUserTap: false) == .allow)
    #expect(BrowserNavigationPolicy.decide(url: nil, isMainFrame: true, isUserTap: true) == .cancel)
    #expect(BrowserNavigationPolicy.handsToSystem(canShow: false, disposition: nil))
    #expect(BrowserNavigationPolicy.handsToSystem(canShow: true, disposition: "attachment; filename=x"))
    #expect(!BrowserNavigationPolicy.handsToSystem(canShow: true, disposition: nil))
  }
}

@Suite("Code preview and annotation")
struct MediaRenderingTests {
  @Test("a small file is tokenized and numbered")
  func codePreviewTokens() {
    let source = "let answer = 42 // the answer\n"
    let preview = CodePreview.make(data: Data(source.utf8), fileName: "Main.swift")
    #expect(preview?.lines.count == 2)
    #expect(preview?.lines.first?.number == 1)
    #expect(preview?.lines.first?.tokens.contains { $0.kind == .keyword } == true)
    #expect(preview?.lines.first?.tokens.contains { $0.kind == .number } == true)
    #expect(preview?.lines.first?.tokens.contains { $0.kind == .comment } == true)
  }

  @Test("long lines fall back to plain lines and oversized reads are refused")
  func codePreviewBounds() {
    let long = String(repeating: "x", count: CodePreview.maximumLineBytes + 1)
    let preview = CodePreview.make(data: Data(long.utf8), fileName: "a.json")
    #expect(preview?.lines.first?.tokens.isEmpty == true)
    let huge = Data(count: Int(MediaLimits.maximumPreviewBytes) + 1)
    #expect(CodePreview.make(data: huge, fileName: "a.txt") == nil)
  }

  @Test("annotation flattens to a bounded JPEG")
  func annotationRenderer() throws {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = try #require(
      CGContext(
        data: nil,
        width: 800,
        height: 600,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    context.setFillColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
    let base = try #require(context.makeImage())
    let stroke = AnnotationStroke(
      points: [AnnotationPoint(x: 0.1, y: 0.1), AnnotationPoint(x: 0.9, y: 0.9)],
      ink: .red
    )
    let data = try #require(AnnotationRenderer.jpeg(base: base, strokes: [stroke], maximumPixelSize: 400))
    #expect(data.prefix(2) == Data([0xFF, 0xD8]))
    let size = try #require(MediaImageEncoding.pixelSize(data))
    #expect(max(size.width, size.height) <= 400)
  }
}

@Suite("File viewer")
@MainActor
struct FileViewerTests {
  @Test("a server text file is read through the client and shown as code")
  func loadsServerText() async throws {
    let environment = IsolatedTestEnvironment(testName: "file-viewer")
    defer { environment.cleanUp() }
    let server = fixtureServer()
    let requested = RequestRecorder()
    let scratch = MediaScratch(directory: try environment.directory("scratch"))
    let store = TestStore(
      initialState: FileViewerFeature.State(
        file: TranscriptFile(id: "f", name: "main.swift", mime: "text/plain", path: "Sources/main.swift", byteCount: 20),
        server: server,
        directory: "/work/app"
      )
    ) {
      FileViewerFeature()
    } withDependencies: {
      $0.mediaScratch = MediaScratchFiles(store: scratch)
      $0.openCodeClient = .testValue
      $0.openCodeClient.readFile = { _, directory, path, maximum in
        await requested.record(directory: directory, path: path, maximum: maximum)
        return Data("let value = 1\n".utf8)
      }
    }
    let preview = try #require(CodePreview.make(data: Data("let value = 1\n".utf8), fileName: "main.swift"))
    await store.send(.task) { $0.load = .loading }
    await store.receive(.loaded(.code(preview))) { $0.load = .code(preview) }
    let calls = await requested.calls
    #expect(calls.count == 1)
    #expect(calls.first?.directory == "/work/app")
    #expect(calls.first?.path == "Sources/main.swift")
  }
}

private actor RequestRecorder {
  struct Call: Sendable, Equatable {
    var directory: String
    var path: String
    var maximum: Int64
  }
  private(set) var calls: [Call] = []

  func record(directory: String, path: String, maximum: Int64) {
    calls.append(Call(directory: directory, path: path, maximum: maximum))
  }
}
