import XCTest

/// P9 composer surfaces. Everything on screen is deterministic fixture data.
@MainActor
final class ComposerScreenshotUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testCaptureComposerSurfaces() {
    capture(style: "light", suffix: "")
    capture(style: "dark", suffix: "-dark")
  }

  private func capture(style: String, suffix: String) {
    let app = XCUIApplication()
    app.launchArguments = [
      "-uiTesting", "-uiTestResetDrafts", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    app.launchEnvironment = [
      "OPENCODE_UI_TEST_FIXTURE": "connected-composer",
      "OPENCODE_UI_TEST_APPEARANCE": style,
    ]
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 30))
    openAlpha(app)
    let field = app.textViews["composer-field"]
    field.tap()
    field.typeText("Draft a release summary for the native composer.")
    attach(app, name: "p9-composer\(suffix)")

    let quote = app.buttons["transcript-quote-reply-end-alpha-reply-1"]
    if quote.waitForExistence(timeout: 3) {
      quote.tap()
      XCTAssertTrue(app.descendants(matching: .any)["quote-selection-sheet"].waitForExistence(timeout: 10))
      attach(app, name: "p9-quote\(suffix)")
      app.buttons["quote-selection-confirm"].tap()
      attach(app, name: "p9-composer-quote\(suffix)")
    }
    app.terminate()

    requestCapture(style: style, suffix: suffix)
    queueCapture(style: style, suffix: suffix)
  }

  private func requestCapture(style: String, suffix: String) {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-uiTestResetDrafts", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launchEnvironment = [
      "OPENCODE_UI_TEST_FIXTURE": "connected-composer-question",
      "OPENCODE_UI_TEST_APPEARANCE": style,
    ]
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 30))
    openAlpha(app)
    XCTAssertTrue(app.descendants(matching: .any)["request-dock"].waitForExistence(timeout: 10))
    attach(app, name: "p9-request-dock\(suffix)")
    app.terminate()
  }

  private func queueCapture(style: String, suffix: String) {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-uiTestResetDrafts", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launchEnvironment = [
      "OPENCODE_UI_TEST_FIXTURE": "connected-composer-queue",
      "OPENCODE_UI_TEST_APPEARANCE": style,
    ]
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 30))
    openAlpha(app)
    app.buttons["composer-queued-pill"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["queued-messages-sheet"].waitForExistence(timeout: 10))
    attach(app, name: "p9-queued\(suffix)")
    app.terminate()
  }

  private func openAlpha(_ app: XCUIApplication) {
    app.buttons["home-drawer-button"].tap()
    let row = app.buttons["drawer-session-row-alpha"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-session"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.textViews["composer-field"].waitForExistence(timeout: 10))
  }

  private func attach(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
