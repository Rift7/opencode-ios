import Foundation
import OpenCodeCore
import Testing

@Suite("Logging privacy")
struct LoggingTests {
  @Test("public text is the event name plus numeric fields")
  func publicTextIsStructured() {
    let record = LogRecord(
      event: .probeFinished,
      fields: [
        LogField("status", .status(200)),
        LogField("duration", .durationMilliseconds(42)),
        LogField("retries", .count(1)),
        LogField("connected", .flag(false)),
      ]
    )

    #expect(record.publicText == "probe.finished connected=false duration=42ms retries=1 status=200")
  }

  @Test("a short credential never reaches public text")
  func shortCredentialStaysPrivate() {
    let record = LogRecord(
      event: .launchFailed,
      privateFields: [LogPrivateField("detail", "hunter2")]
    )

    #expect(!record.publicText.contains("hunter2"))
    #expect(record.publicText == "launch.failed")
  }

  @Test("a personal path never reaches public text")
  func personalPathStaysPrivate() {
    let path = "/home/fixture/private/notes.txt"
    let record = LogRecord(
      event: .transportBlocked,
      fields: [LogField("status", .status(0))],
      privateFields: [LogPrivateField("path", path)]
    )

    #expect(!record.publicText.contains("/home"))
    #expect(!record.publicText.contains("someone"))
    #expect(record.publicText == "transport.blocked status=0")
  }

  @Test("ordinary message text never reaches public text")
  func messageTextStaysPrivate() {
    let body = "Send the deploy script to op@example.com and delete the old keys"
    let record = LogRecord(
      event: .screenShown,
      privateFields: [LogPrivateField("message", body)]
    )

    #expect(!record.publicText.contains("deploy"))
    #expect(!record.publicText.contains("op@example.com"))
    #expect(record.publicText == "screen.shown")
  }

  @Test("a server address stays out of public text")
  func addressStaysPrivate() {
    let record = LogRecord(
      event: .probeStarted,
      privateFields: [LogPrivateField("address", "https://host.invalid:4110")]
    )

    #expect(!record.publicText.contains("host.invalid"))
    #expect(!record.publicText.contains("4110"))
  }

  @Test("only AppLog publishes with public visibility")
  func publicVisibilityIsConfined() throws {
    let iosRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()

    var files: [URL] = []
    for directory in [
      iosRoot.appendingPathComponent("OpenCodeKit/Sources", isDirectory: true),
      iosRoot.appendingPathComponent("OpenCode", isDirectory: true),
    ] {
      let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
      files += (enumerator?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
    }

    #expect(files.count > 6)

    for file in files where file.lastPathComponent != "AppLog.swift" {
      let contents = try String(contentsOf: file, encoding: .utf8)
      #expect(
        !contents.contains("privacy: .public"),
        "\(file.lastPathComponent) publishes log text directly; use AppLog"
      )
    }
  }
}
