import XCTest

/// Captures the P7 session surfaces for review. Everything on screen is fixture data.
final class SessionScreenshotUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testCaptureSessionSurfaces() {
    capture(style: nil, suffix: "")
    capture(style: "Dark", suffix: "-dark")
  }

  private func capture(style: String?, suffix: String) {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launchEnvironment = [
      "OPENCODE_UI_TEST_FIXTURE": "connected",
      "OPENCODE_UI_TEST_APPEARANCE": style == nil ? "light" : "dark",
    ]
    app.launch()

    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 15))
    app.buttons["home-drawer-button"].tap()
    let row = app.buttons["drawer-session-row-alpha"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-session"].waitForExistence(timeout: 10))
    attach(app, name: "p7-session\(suffix)")

    app.buttons["session-review-requests"].tap()
    XCTAssertTrue(app.buttons["request-permission-allow-once"].waitForExistence(timeout: 10))
    attach(app, name: "p7-request\(suffix)")
    app.buttons["request-review-close"].tap()

    app.buttons["session-background"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["background-work-panel"].waitForExistence(timeout: 10))
    attach(app, name: "p7-background\(suffix)")

    app.terminate()
  }

  private func attach(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
