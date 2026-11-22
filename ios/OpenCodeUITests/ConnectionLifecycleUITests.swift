import XCTest

/// Exercises the real app reducer with a deterministic in-app client: restore, connect, background
/// cancellation and foreground reconnection all run without a socket.
final class ConnectionLifecycleUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testConnectedShellReconnectsAfterBackground() {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launchEnvironment = ["OPENCODE_UI_TEST_FIXTURE": "connected"]
    app.launch()

    XCTAssertTrue(
      app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 15)
    )
    XCTAssertTrue(app.staticTexts["Fixture"].exists)

    XCUIDevice.shared.press(.home)
    sleep(1)
    app.activate()

    XCTAssertTrue(
      app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 15)
    )
    XCTAssertTrue(app.staticTexts["Connected"].exists)
  }
}
