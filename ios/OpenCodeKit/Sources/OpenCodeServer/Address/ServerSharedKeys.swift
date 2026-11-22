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

  public static let cachedSummaries = SharedKey<[String: CachedServerSummary]>(
    name: "cached-server-summaries",
    defaultValue: [:],
    storage: .userDefaults
  )

  public static let names: [String] = [
    savedServer.name,
    savedServers.name,
    cachedSummaries.name,
  ]
}
