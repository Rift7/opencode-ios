import XCTest

/// Launch smoke tests: the app must reach a stable, labelled state without a server and without
/// touching the network.
final class LaunchSmokeTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testFirstLaunchShowsDisconnectedState() {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launchEnvironment = ["OPENCODE_UI_TEST_PHASE": "disconnected"]
    app.launch()

    XCTAssertTrue(
      app.descendants(matching: .any)["root-phase-disconnected"].waitForExistence(timeout: 10)
    )
    XCTAssertTrue(app.staticTexts["OpenCode"].exists)
    XCTAssertTrue(app.buttons["Connect"].exists)
  }

  func testFailureStateOffersRetry() {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launchEnvironment = ["OPENCODE_UI_TEST_PHASE": "failed"]
    app.launch()

    XCTAssertTrue(
      app.descendants(matching: .any)["root-phase-failed"].waitForExistence(timeout: 10)
    )
    XCTAssertTrue(app.staticTexts["Couldn’t reach the OpenCode server."].exists)
    XCTAssertTrue(app.buttons["Try Again"].exists)
  }

  func testLoadingStateIsReachable() {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launchEnvironment = ["OPENCODE_UI_TEST_PHASE": "loading"]
    app.launch()

    XCTAssertTrue(
      app.descendants(matching: .any)["root-phase-loading"].waitForExistence(timeout: 10)
    )
  }
}
