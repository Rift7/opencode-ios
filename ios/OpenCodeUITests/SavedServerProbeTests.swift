import XCTest

/// The hostless unit bundle cannot reach the Keychain, so the real restore read runs in the app
/// process with a disposable service.
final class SavedServerProbeTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testSavedServersRestoreFromTheKeychainInTheAppProcess() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-uiTesting", "-uiTestScenario", "disconnected", "-uiTestSavedServerRestoreProbe",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    app.launch()

    XCTAssertTrue(
      app.staticTexts["saved-server-probe-passed"].waitForExistence(timeout: 10),
      "Saved-server restore probe did not pass in the app process"
    )
  }
}
