import XCTest

/// The hostless unit bundle cannot reach the Keychain (no entitlement), so the real round trip is
/// exercised in the app process instead.
final class KeychainProbeTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testKeychainRoundTripInTheAppProcess() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-uiTesting", "-uiTestKeychainProbe", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    app.launch()

    XCTAssertTrue(
      app.staticTexts["keychain-probe-passed"].waitForExistence(timeout: 10),
      "Keychain round trip did not pass in the app process"
    )
  }
}
