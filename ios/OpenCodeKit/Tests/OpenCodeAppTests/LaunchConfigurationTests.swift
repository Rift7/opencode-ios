import OpenCodeApp
import OpenCodeCore
import Testing

@Suite("Launch configuration")
struct LaunchConfigurationTests {
  @Test("first launch starts disconnected")
  func firstLaunch() {
    let state = AppLaunchConfiguration().initialState
    #expect(state.restore == .idle)
    #expect(state.connection == nil)
    #expect(state.isPinnedForUITest == false)
  }

  @Test("a UI-test scenario maps to its pinned state")
  func scenariosMap() {
    #expect(AppLaunchConfiguration(uiTestScenario: .disconnected).initialState.connection == nil)
    #expect(
      AppLaunchConfiguration(uiTestScenario: .connecting).initialState.connection?.phase == .connecting
    )
    #expect(AppLaunchConfiguration(uiTestScenario: .loading).initialState.connection?.phase == .loading)
    #expect(AppLaunchConfiguration(uiTestScenario: .connected).initialState.connection?.phase == .connected)
    #expect(
      AppLaunchConfiguration(uiTestScenario: .reconnecting).initialState.connection?.phase == .reconnecting
    )
    #expect(
      AppLaunchConfiguration(uiTestScenario: .failedAuth).initialState.connection?.failure
        == .credentialsRejected
    )
    #expect(
      AppLaunchConfiguration(uiTestScenario: .failedIncompatible).initialState.connection?.failure
        == .incompatibleAPI(feature: "server info")
    )
    #expect(
      AppLaunchConfiguration(uiTestScenario: .failedUnreachable).initialState.connection?.failure
        == .unreachable
    )
    #expect(
      AppLaunchConfiguration(uiTestScenario: .storageUnavailable).initialState.restore
        == .storageUnavailable(.unavailable)
    )
    #expect(
      AppLaunchConfiguration(uiTestScenario: .corruptSaved).initialState.restore == .corruptSavedServers
    )
    #expect(
      AppLaunchConfiguration(uiTestScenario: .pairingConfirm).initialState.pendingPairing != nil
    )
  }

  @Test("a UI-test scenario never reaches the network")
  func pinnedStates() {
    for scenario in AppLaunchConfiguration.UITestScenario.allCases {
      #expect(AppLaunchConfiguration(uiTestScenario: scenario).initialState.isPinnedForUITest)
    }
  }

  @Test("an unknown override value falls back to first launch")
  func unknownScenarioFallsBack() {
    #expect(AppLaunchConfiguration.UITestScenario(rawValue: "nonsense") == nil)
  }
}
