import Dependencies
import Foundation
import OpenCodeCore
import Testing

private struct TransportProbe {
  @Dependency(\.httpTransport) var transport
}

@Suite("Transport boundary")
struct TransportBoundaryTests {
  private static let request = HTTPRequest(url: URL(string: "https://example.com/api/info")!)

  @Test("an unoverridden dependency performs no network work")
  func unoverriddenDependencyIsInert() async {
    // No override: the test context must resolve the inert value on its own.
    let probe = TransportProbe()

    await #expect(throws: TransportError.blocked) {
      _ = try await probe.transport.send(Self.request)
    }
    await #expect(throws: TransportError.blocked) {
      _ = try await probe.transport.open(Self.request)
    }
  }

  @Test("the test value blocks even when a feature forgets to override it")
  func testValueBlocks() async {
    let transport = HTTPTransport.testValue

    await #expect(throws: TransportError.blocked) {
      _ = try await transport.send(Self.request)
    }
    await #expect(throws: TransportError.blocked) {
      _ = try await transport.open(Self.request)
    }
  }

  @Test("no source file creates its own URLSession")
  func noFeatureOwnsASession() throws {
    let iosRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()

    let tree = [
      iosRoot.appendingPathComponent("OpenCodeKit/Sources", isDirectory: true),
      iosRoot.appendingPathComponent("OpenCode", isDirectory: true),
    ]

    var files: [URL] = []
    for directory in tree {
      let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
      files += (enumerator?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
    }

    #expect(files.count > 4)

    // Only the test-only guard library and the transport seam may own a session.
    func ownsASession(_ file: URL) -> Bool {
      let path = file.path
      return path.contains("/OpenCodeTestSupport/") || path.contains("/OpenCodeCore/Transport/")
    }

    for file in files {
      let contents = try String(contentsOf: file, encoding: .utf8)
      let name = file.lastPathComponent
      #expect(
        !contents.contains("URLSession.shared"),
        "\(name) uses URLSession.shared; route requests through HTTPTransport"
      )
      if !ownsASession(file) {
        #expect(
          !contents.contains("URLSession("),
          "\(name) creates a URLSession; only the transport seam may do that"
        )
      }
    }
  }
}
