import XCTest

/// Captures the P6 surfaces for review. The test only reads the deterministic fixture; screenshots
/// carry synthetic session names and no server address or credential.
final class HomeScreenshotUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testCaptureHomeAndDrawer() {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launchEnvironment = ["OPENCODE_UI_TEST_FIXTURE": "connected"]
    app.launch()

    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["Alpha release notes"].waitForExistence(timeout: 15))
    attach(app, name: "p6-home")

    app.buttons["home-drawer-button"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["drawer"].waitForExistence(timeout: 10))
    attach(app, name: "p6-drawer")

    app.buttons["drawer-catch-up"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["catch-up-card"].waitForExistence(timeout: 10))
    attach(app, name: "p6-catch-up")
  }

  private func attach(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
