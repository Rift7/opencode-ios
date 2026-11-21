import OpenCodeApp
import OpenCodeCore
import Testing

@Suite("Launch configuration")
struct LaunchConfigurationTests {
  @Test("first launch starts disconnected")
  func firstLaunch() {
    #expect(AppLaunchConfiguration().initialState.phase == .disconnected)
  }

  @Test("a UI-test phase override maps to its state")
  func overridesMap() {
    #expect(AppLaunchConfiguration(uiTestPhase: .disconnected).initialState.phase == .disconnected)
    #expect(AppLaunchConfiguration(uiTestPhase: .loading).initialState.phase == .loading)
    #expect(AppLaunchConfiguration(uiTestPhase: .failed).initialState.phase == .failed(.unreachable))
    #expect(AppLaunchConfiguration(uiTestPhase: .connected).initialState.phase == .connected)
  }

  @Test("an unknown override value falls back to first launch")
  func unknownPhaseFallsBack() {
    #expect(AppLaunchConfiguration.UITestPhase(rawValue: "nonsense") == nil)
  }
}
