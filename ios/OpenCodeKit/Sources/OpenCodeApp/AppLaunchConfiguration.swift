import Foundation

/// Launch-time state, overridable from the command line so UI tests can pin a phase. The override
/// is only honoured when the process was started by a test runner.
public struct AppLaunchConfiguration: Sendable {
  public enum UITestPhase: String, Sendable {
    case disconnected
    case loading
    case failed
    case connected
  }

  public let uiTestPhase: UITestPhase?

  public init(uiTestPhase: UITestPhase? = nil) {
    self.uiTestPhase = uiTestPhase
  }

  public var initialState: AppFeature.State {
    switch uiTestPhase {
    case .disconnected, nil:
      AppFeature.State(phase: .disconnected)
    case .loading:
      AppFeature.State(phase: .loading)
    case .failed:
      AppFeature.State(phase: .failed(.unreachable))
    case .connected:
      AppFeature.State(phase: .connected)
    }
  }

  public static var current: AppLaunchConfiguration {
    let process = ProcessInfo.processInfo
    guard process.arguments.contains("-uiTesting") else {
      return AppLaunchConfiguration()
    }

    let value = process.environment["OPENCODE_UI_TEST_PHASE"] ?? argumentValue(after: "-uiTestPhase")
    return AppLaunchConfiguration(uiTestPhase: value.flatMap(UITestPhase.init(rawValue:)))
  }

  private static func argumentValue(after flag: String) -> String? {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
      return nil
    }
    return arguments[index + 1]
  }
}
