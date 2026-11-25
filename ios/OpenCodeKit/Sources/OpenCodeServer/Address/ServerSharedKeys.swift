import Foundation
import OpenCodeCore

/// A small launch cache: the project list that was last read from a server, so a restored
/// connection can show what it knows while it revalidates. REST remains authoritative.
public struct CachedServerSummary: Codable, Sendable, Equatable {
  public var projects: [ServerProject]
  public var version: String?
  public var capturedAt: Date

  public init(projects: [ServerProject], version: String? = nil, capturedAt: Date) {
    self.projects = projects
    self.version = version
    self.capturedAt = capturedAt
  }
}

/// A pending two-key server write. It lives in the Keychain because it carries credentials; a
/// restart uses it to roll both records back to the last coherent state.
public struct ServerWriteIntent: Codable, Sendable, Equatable {
  public var id: UUID
  public var beforeServer: OpenCodeServer?
  public var beforeServers: [OpenCodeServer]
  public var afterServer: OpenCodeServer?
  public var afterServers: [OpenCodeServer]
  /// An explicit recovery operation preserves the exact bytes it is replacing, including records
  /// that no longer decode. Ordinary operations leave these nil and use the typed fields.
  public var preserveRawBefore: Bool?
  public var beforeRawServer: Data?
  public var beforeRawServers: Data?

  public init(
    id: UUID,
    beforeServer: OpenCodeServer?,
    beforeServers: [OpenCodeServer],
    afterServer: OpenCodeServer?,
    afterServers: [OpenCodeServer],
    preserveRawBefore: Bool? = nil,
    beforeRawServer: Data? = nil,
    beforeRawServers: Data? = nil
  ) {
    self.id = id
    self.beforeServer = beforeServer
    self.beforeServers = beforeServers
    self.afterServer = afterServer
    self.afterServers = afterServers
    self.preserveRawBefore = preserveRawBefore
    self.beforeRawServer = beforeRawServer
    self.beforeRawServers = beforeRawServers
  }
}

/// The server-typed shared keys. The last-used server and the saved list carry credentials, so
/// they live in the Keychain; the launch cache is ordinary preference data.
public enum ServerSharedKeys {
  public static let savedServer = SharedKey<OpenCodeServer?>(
    name: "saved-server",
    defaultValue: nil,
    storage: .keychain
  )

  public static let savedServers = SharedKey<[OpenCodeServer]>(
    name: "saved-servers",
    defaultValue: [],
    storage: .keychain
  )

  public static let writeIntent = SharedKey<ServerWriteIntent?>(
    name: "server-write-intent",
    defaultValue: nil,
    storage: .keychain
  )

  public static let cachedSummaries = SharedKey<[String: CachedServerSummary]>(
    name: "cached-server-summaries",
    defaultValue: [:],
    storage: .userDefaults
  )

  public static let names: [String] = [
    savedServer.name,
    savedServers.name,
    writeIntent.name,
    cachedSummaries.name,
  ]
}
