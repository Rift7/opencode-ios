import Foundation
import OpenCodeCore

/// One test's private world: a temporary directory that is removed on `cleanUp`, an in-memory
/// key-value store, pinned time and a deterministic identifier sequence. Nothing here touches the
/// developer's home directory, the app's real defaults or the network.
public struct IsolatedTestEnvironment: Sendable {
  public let root: URL
  public let storage: InMemoryStorage
  public let now: Date
  public let uuid: UuidClient

  public init(
    testName: String,
    now: Date = Date(timeIntervalSince1970: 1_700_000_000),
    uuid: UuidClient = UuidClient.incrementing()
  ) {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("opencode-migration-tests", isDirectory: true)
    let token = "\(testName)-\(UUID().uuidString)"
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: " ", with: "-")
    root = base.appendingPathComponent(token, isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    storage = InMemoryStorage()
    self.now = now
    self.uuid = uuid
  }

  /// A private subdirectory, created on demand.
  public func directory(_ name: String) throws -> URL {
    let url = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  public func cleanUp() {
    try? FileManager.default.removeItem(at: root)
  }
}

/// Values that describe a server the tests may talk to without leaving the machine. The host uses
/// the reserved `.invalid` TLD, so a real DNS lookup could never resolve it.
public enum InertFixtures {
  public static let fixtureHost = "wire-00000000-0000-4000-8000-000000000000.invalid"
  public static let fixtureBaseURL = "https://\(fixtureHost)"
  public static let publicURL = "https://example.com/api/info"
}
