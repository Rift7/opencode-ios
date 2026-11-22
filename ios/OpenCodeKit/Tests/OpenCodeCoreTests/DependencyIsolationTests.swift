import Foundation
import OpenCodeCore
import Testing

@Suite("Dependency isolation")
struct DependencyIsolationTests {
  @Test("every dependency key declares an inert test value")
  func everyKeyHasATestValue() throws {
    let sourcesRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources", isDirectory: true)

    let enumerator = FileManager.default.enumerator(
      at: sourcesRoot,
      includingPropertiesForKeys: nil
    )
    let files = (enumerator?.compactMap { $0 as? URL } ?? [])
      .filter { $0.pathExtension == "swift" }

    #expect(files.count > 4)

    var keyCount = 0
    for file in files {
      let contents = try String(contentsOf: file, encoding: .utf8)
      let keys = contents.components(separatedBy: ": DependencyKey").count - 1
      let testValues = contents.components(separatedBy: "testValue").count - 1
      keyCount += keys

      #expect(
        testValues >= keys,
        "\(file.lastPathComponent) declares \(keys) dependency key(s) but only \(testValues) test value(s)"
      )
    }

    #expect(keyCount >= 5)
  }
}
