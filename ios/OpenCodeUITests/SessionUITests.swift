import XCTest

/// Session selection, subagent navigation, request review and failure recovery against the
/// deterministic in-app fixture.
final class SessionUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  private func launch(mode: String = "connected") -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launchEnvironment = ["OPENCODE_UI_TEST_FIXTURE": mode]
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 15))
    return app
  }

  private func openAlpha(_ app: XCUIApplication) {
    let drawer = app.buttons["home-drawer-button"]
    XCTAssertTrue(drawer.waitForExistence(timeout: 10))
    drawer.tap()
    let row = app.buttons["drawer-session-row-alpha"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-session"].waitForExistence(timeout: 10))
  }

  func testSessionAndSubagentNavigation() {
    let app = launch()
    openAlpha(app)
    XCTAssertTrue(app.staticTexts["session-title"].waitForExistence(timeout: 10))

    app.buttons["session-subagents"].tap()
    let child = app.buttons["subagent-alpha-child"]
    XCTAssertTrue(child.waitForExistence(timeout: 10))
    child.tap()

    XCTAssertTrue(app.buttons["session-page-back"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Explore the composer"].waitForExistence(timeout: 10))
    app.buttons["session-page-back"].tap()
    XCTAssertTrue(app.staticTexts["Alpha release notes"].waitForExistence(timeout: 10))

    app.buttons["session-done"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 10))
  }

  func testPermissionApprovalAndRejection() {
    let app = launch()
    openAlpha(app)

    app.buttons["session-review-requests"].tap()
    XCTAssertTrue(app.buttons["request-permission-allow-once"].waitForExistence(timeout: 10))
    app.buttons["request-permission-allow-once"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-session"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["session-review-requests"].exists)

    app.buttons["session-done"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 10))
  }

  func testPermissionRejectionDismissesTheRequest() {
    let app = launch()
    openAlpha(app)

    app.buttons["session-review-requests"].tap()
    XCTAssertTrue(app.buttons["request-permission-deny"].waitForExistence(timeout: 10))
    app.buttons["request-permission-deny"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-session"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["session-review-requests"].exists)
  }

  func testFormValidationAndSubmission() {
    let app = launch(mode: "connected-form")
    openAlpha(app)

    app.buttons["session-review-requests"].tap()
    XCTAssertTrue(app.buttons["request-option-staging"].waitForExistence(timeout: 10))
    app.buttons["request-send"].tap()
    XCTAssertTrue(app.staticTexts["This field is required."].waitForExistence(timeout: 10))

    app.buttons["request-option-staging"].tap()
    app.buttons["request-field-confirm-yes"].tap()
    app.buttons["request-send"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-session"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["session-review-requests"].exists)
  }

  func testFailedReplyKeepsTheAnswerAndRetries() {
    let app = launch(mode: "connected-request-failure")
    openAlpha(app)

    app.buttons["session-review-requests"].tap()
    app.buttons["request-permission-allow-once"].tap()
    XCTAssertTrue(app.staticTexts["Couldn’t send reply"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["request-permission-allow-once"].exists)

    app.buttons["request-permission-allow-once"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-session"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["session-review-requests"].exists)
  }
}
