import Foundation
import OpenCodeCore
import OpenCodeServer

// MARK: - Preferences

public enum AppearanceChoice: String, CaseIterable, Codable, Sendable, Equatable {
  case system
  case light
  case dark

  public var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }
}

/// The typed preferences Settings owns. Every value has a stable storage name and default.
public struct SettingsPreferences: Equatable, Sendable {
  public var appearance: AppearanceChoice
  public var returnKeySends: Bool
  public var fileViewerWrapsLines: Bool
  public var inAppBrowser: Bool
  public var onboardingCompleted: Bool

  public init(
    appearance: AppearanceChoice = .system,
    returnKeySends: Bool = false,
    fileViewerWrapsLines: Bool = false,
    inAppBrowser: Bool = false,
    onboardingCompleted: Bool = false
  ) {
    self.appearance = appearance
    self.returnKeySends = returnKeySends
    self.fileViewerWrapsLines = fileViewerWrapsLines
    self.inAppBrowser = inAppBrowser
    self.onboardingCompleted = onboardingCompleted
  }
}

public enum SettingsPreference: String, CaseIterable, Sendable {
  case appearance
  case returnKeySends
  case fileViewerWrapsLines
  case inAppBrowser
  case onboardingCompleted
}

public enum PreferencesProblem: Equatable, Sendable {
  case storage(StorageFailure)
  case corrupt
}

public struct SettingsPage: Equatable, Sendable, Hashable {
  public enum Kind: String, Equatable, Sendable, Hashable {
    case appearance
    case sessions
    case servers
    case server
    case experimental
    case diagnostics
    case onboarding
    case help
  }

  public var kind: Kind
  public var serverID: String?

  public init(kind: Kind, serverID: String? = nil) {
    self.kind = kind
    self.serverID = serverID
  }
}

// MARK: - Server editing

/// The editable part of a saved server. Credentials stay in the saved record until Save succeeds;
/// the form holds them only in memory and never logs or copies them.
public struct ServerEditForm: Equatable, Sendable {
  public var original: OpenCodeServer
  public var name: String
  public var address: String
  public var username: String
  public var password: String
  public var headers: [OpenCodeServer.Header]
  public var problem: Problem?
  public var headerProblem: HeaderProblem?

  public enum Problem: Equatable, Sendable {
    case emptyAddress
    case invalidAddress(ServerOrigin.Problem)
    case noChanges
  }

  public enum HeaderProblem: Equatable, Sendable {
    case emptyName(index: Int)
    case invalidName(index: Int, name: String)
    case invalidValue(index: Int, name: String)
    case forbidden(index: Int, name: String)
  }

  public init(_ server: OpenCodeServer) {
    original = server
    name = server.name ?? ""
    address = server.url
    username = server.username
    password = server.password
    headers = server.headers
    problem = nil
    headerProblem = nil
  }

  public var candidate: OpenCodeServer? {
    let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard case .success(let origin) = ServerOrigin.parse(trimmed) else { return nil }
    let shortName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
    return OpenCodeServer(
      url: origin.address,
      username: user.isEmpty ? "opencode" : user,
      password: password,
      alternateURLs: original.alternateURLs,
      name: shortName.isEmpty ? nil : shortName,
      headers: headers,
      preferredURLs: original.preferredURLs
    )
  }

  /// Performs the same validation as the wire policy. A blank row the person is still typing is
  /// reported rather than silently dropped.
  public mutating func validate() -> OpenCodeServer? {
    problem = nil
    headerProblem = nil
    let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      problem = .emptyAddress
      return nil
    }
    switch ServerOrigin.parse(trimmed) {
    case .failure(let problem):
      self.problem = .invalidAddress(problem)
      return nil
    case .success:
      break
    }
    for (index, header) in headers.enumerated() {
      switch header.problem {
      case .none:
        continue
      case .emptyName:
        headerProblem = .emptyName(index: index)
      case .invalidName:
        headerProblem = .invalidName(index: index, name: header.name)
      case .invalidValue:
        headerProblem = .invalidValue(index: index, name: header.name)
      case .forbiddenName:
        headerProblem = .forbidden(index: index, name: header.name)
      }
      return nil
    }
    guard let candidate else {
      problem = .invalidAddress(.notAWebAddress)
      return nil
    }
    return candidate
  }
}

public enum ServerRemovalProblem: Equatable, Sendable {
  case storage(StorageFailure)
  case lastServer
}

public enum ServerForgetResult: Equatable, Sendable {
  case removed
  case failure(StorageFailure)
}

// MARK: - Diagnostics

/// The allow-listed facts a copied report may contain. There is deliberately no free-form string
/// field for an error, URL, header, message or path.
public struct DiagnosticFacts: Equatable, Sendable {
  public enum Phase: String, Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed
    case pairing
  }

  public enum FailureKind: String, Equatable, Sendable {
    case none
    case invalidAddress
    case unreachable
    case offline
    case timedOut
    case credentialsRejected
    case incompatibleAPI
    case malformed
    case serverStatus
    case pairingExpired
    case pairingUnsupported
    case stream
    case unsupported
  }

  public var appVersion: String
  public var build: String
  public var phase: Phase
  public var failure: FailureKind
  public var statusCode: Int?
  public var savedServers: Int
  public var projects: Int
  public var sessions: Int
  public var transcriptRows: Int
  public var drafts: Int
  public var activeRequests: Int

  public init(
    appVersion: String,
    build: String,
    phase: Phase,
    failure: FailureKind = .none,
    statusCode: Int? = nil,
    savedServers: Int = 0,
    projects: Int = 0,
    sessions: Int = 0,
    transcriptRows: Int = 0,
    drafts: Int = 0,
    activeRequests: Int = 0
  ) {
    self.appVersion = appVersion
    self.build = build
    self.phase = phase
    self.failure = failure
    self.statusCode = statusCode
    self.savedServers = savedServers
    self.projects = projects
    self.sessions = sessions
    self.transcriptRows = transcriptRows
    self.drafts = drafts
    self.activeRequests = activeRequests
  }
}

/// A report built only from typed facts. Fields are emitted in a fixed order.
public struct DiagnosticReport: Equatable, Sendable {
  public var lines: [String]

  public init(facts: DiagnosticFacts, generatedAt: Date) {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    lines = [
      "OpenCode diagnostics",
      "App: \(facts.appVersion) (\(facts.build))",
      "Generated: \(iso.string(from: generatedAt))",
      "Phase: \(facts.phase.rawValue)",
      "Failure: \(facts.failure.rawValue)",
      "HTTP status: \(facts.statusCode.map(String.init) ?? "none")",
      "Saved servers: \(facts.savedServers)",
      "Projects: \(facts.projects)",
      "Sessions: \(facts.sessions)",
      "Transcript rows: \(facts.transcriptRows)",
      "Drafts: \(facts.drafts)",
      "Active requests: \(facts.activeRequests)",
    ]
  }

  public var text: String { lines.joined(separator: "\n") }
}

// MARK: - Pairing scan boundary

public enum PairingScanEvent: Equatable, Sendable {
  case code(String)
  case denied
  case restricted
  case unavailable
  case failed
}

/// The camera scan boundary. Production emits decoded QR payloads from AVFoundation; simulator
/// tests inject a scripted stream through this same client.
public struct PairingScannerClient: Sendable {
  public var start: @Sendable () async -> AsyncStream<PairingScanEvent>
  public var stop: @Sendable () -> Void

  public init(
    start: @escaping @Sendable () async -> AsyncStream<PairingScanEvent>,
    stop: @escaping @Sendable () -> Void = {}
  ) {
    self.start = start
    self.stop = stop
  }
}

public enum PairingScanProblem: Equatable, Sendable {
  case cameraDenied
  case cameraRestricted
  case cameraUnavailable
  case cameraFailed
}
