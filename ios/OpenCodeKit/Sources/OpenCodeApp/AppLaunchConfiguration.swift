import Foundation
import OpenCodeCore
import OpenCodeDrawer
import OpenCodeServer

/// Launch-time state, overridable from the command line so UI tests can pin a screen. Overrides are
/// honoured only when the process was started by a test runner.
public struct AppLaunchConfiguration: Sendable {
  public enum UITestScenario: String, Sendable, CaseIterable {
    case disconnected
    case connecting
    case loading
    case connected
    case reconnecting
    case failedAuth = "failed-auth"
    case failedIncompatible = "failed-incompatible"
    case failedOffline = "failed-offline"
    case failedUnreachable = "failed-unreachable"
    case storageUnavailable = "storage-unavailable"
    case corruptSaved = "corrupt-saved"
    case pairingConfirm = "pairing-confirm"
  }

  public let uiTestScenario: UITestScenario?
  public let uiTestOpenURL: String?
  public let uiTestClipboard: String?
  /// Use the in-app deterministic client instead of the network. Test runner only.
  public let usesFixtureClient: Bool

  /// Which synthetic data set the fixture client serves (`connected` or `connected-scroll`).
  public let uiTestFixture: String?
  /// A UI test's requested appearance (`OPENCODE_UI_TEST_APPEARANCE`); nil uses the system.
  public let uiTestAppearance: String?

  public init(
    uiTestScenario: UITestScenario? = nil,
    uiTestOpenURL: String? = nil,
    uiTestClipboard: String? = nil,
    usesFixtureClient: Bool = false,
    uiTestFixture: String? = nil,
    uiTestAppearance: String? = nil
  ) {
    self.uiTestScenario = uiTestScenario
    self.uiTestOpenURL = uiTestOpenURL
    self.uiTestClipboard = uiTestClipboard
    self.usesFixtureClient = usesFixtureClient
    self.uiTestFixture = uiTestFixture
    self.uiTestAppearance = uiTestAppearance
  }

  public var initialState: AppFeature.State {
    guard let uiTestScenario else { return AppFeature.State() }
    switch uiTestScenario {
    case .disconnected:
      return AppFeature.State(isPinnedForUITest: true)
    case .connecting:
      return AppFeature.State(
        restore: .ready,
        connection: pinnedConnection(phase: .connecting),
        isPinnedForUITest: true
      )
    case .loading:
      return AppFeature.State(
        restore: .ready,
        connection: pinnedConnection(phase: .loading),
        isPinnedForUITest: true
      )
    case .connected:
      return AppFeature.State(
        restore: .ready,
        connection: pinnedConnection(phase: .connected),
        home: pinnedHome,
        savedServer: pinnedServer,
        savedServers: [pinnedServer],
        isPinnedForUITest: true
      )
    case .reconnecting:
      return AppFeature.State(
        restore: .ready,
        connection: pinnedConnection(phase: .reconnecting),
        savedServer: pinnedServer,
        savedServers: [pinnedServer],
        isPinnedForUITest: true
      )
    case .failedAuth:
      return failure(.credentialsRejected)
    case .failedIncompatible:
      return failure(.incompatibleAPI(feature: "server info"))
    case .failedOffline:
      return failure(.offline)
    case .failedUnreachable:
      return failure(.unreachable)
    case .storageUnavailable:
      return AppFeature.State(
        restore: .storageUnavailable(.unavailable),
        isPinnedForUITest: true,
        savedData: .unreadable(.storage(.unavailable))
      )
    case .corruptSaved:
      return AppFeature.State(
        restore: .corruptSavedServers,
        isPinnedForUITest: true,
        savedData: .unreadable(.corrupt)
      )
    case .pairingConfirm:
      let link = PairingLink(
        origin: "https://studio.invalid",
        code: "Pair-123_xyz",
        alternateOrigins: ["https://studio.ts.net"]
      )
      return AppFeature.State(
        restore: .ready,
        pendingPairing: PairingConfirmation(
          id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
          link: link,
          replacedServerNames: []
        ),
        isPinnedForUITest: true
      )
    }
  }

  private var pinnedServer: OpenCodeServer {
    OpenCodeServer(
      url: "https://studio.invalid",
      username: "opencode",
      password: "",
      name: "Studio"
    )
  }

  private var pinnedInfo: ServerInfo {
    ServerInfo(version: "0.0.0-fixture", pid: 1)
  }

  private var pinnedProjects: [ServerProject] {
    [
      ServerProject(id: "p1", name: "OpenCode", directory: "/work/opencode"),
      ServerProject(id: "p2", name: "Design", directory: "/work/design"),
    ]
  }

  private var pinnedHome: HomeFeature.State {
    HomeFeature.State(
      server: pinnedServer,
      projects: pinnedProjects,
      sessions: [
        OpenCodeSession(
          id: "pinned-session",
          serverTitle: "Migration check",
          projectID: "p1",
          directory: "/work/opencode",
          updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
          idleMilliseconds: 2_000,
          viewedMilliseconds: 1_000
        )
      ],
      activeSessionIDs: [],
      hasLoaded: true,
      isPinned: true
    )
  }

  private func pinnedConnection(phase: ConnectionFeature.State.Phase) -> ConnectionFeature.State {
    ConnectionFeature.State(
      id: 1,
      server: pinnedServer,
      phase: phase,
      info: pinnedInfo,
      projects: pinnedProjects,
      isPinned: true
    )
  }

  private func failure(_ failure: ConnectionFailure) -> AppFeature.State {
    AppFeature.State(
      restore: .ready,
      connection: ConnectionFeature.State(
        id: 1,
        server: pinnedServer,
        phase: .failed,
        info: nil,
        projects: pinnedProjects,
        failure: failure,
        isPinned: true
      ),
      savedServer: pinnedServer,
      savedServers: [pinnedServer],
      isPinnedForUITest: true
    )
  }

  public static var current: AppLaunchConfiguration {
    let process = ProcessInfo.processInfo
    guard process.arguments.contains("-uiTesting") else {
      return AppLaunchConfiguration()
    }

    let scenario = process.environment["OPENCODE_UI_TEST_SCENARIO"]
      ?? argumentValue(after: "-uiTestScenario")
    let fixture = process.environment["OPENCODE_UI_TEST_FIXTURE"]
    return AppLaunchConfiguration(
      uiTestScenario: scenario.flatMap(UITestScenario.init(rawValue:)),
      uiTestOpenURL: process.environment["OPENCODE_UI_TEST_OPEN_URL"] ?? argumentValue(after: "-uiTestOpenURL"),
      uiTestClipboard: process.environment["OPENCODE_UI_TEST_CLIPBOARD"] ?? argumentValue(after: "-uiTestClipboard"),
      usesFixtureClient: fixture?.hasPrefix("connected") == true,
      uiTestFixture: fixture,
      uiTestAppearance: process.environment["OPENCODE_UI_TEST_APPEARANCE"]
    )
  }

  private static func argumentValue(after flag: String) -> String? {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
      return nil
    }
    return arguments[index + 1]
  }
}
