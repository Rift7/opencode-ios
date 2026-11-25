import XCTest

/// Captures the P11 surfaces against synthetic fixtures. No server address, credential, message
/// text or personal path is in frame beyond the synthetic `/work/opencode` fixture paths.
@MainActor
final class SettingsScreenshotUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  private func launch(appearance: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-uiTesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
      "-uiTestResetSettings", "-uiTestResetDrafts",
    ]
    app.launchEnvironment = [
      "OPENCODE_UI_TEST_FIXTURE": "connected-composer",
      "OPENCODE_UI_TEST_APPEARANCE": appearance,
    ]
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 30))
    return app
  }

  private func openSettings(_ app: XCUIApplication) {
    app.buttons["home-drawer-button"].tap()
    XCTAssertTrue(app.buttons["drawer-settings"].waitForExistence(timeout: 10))
    app.buttons["drawer-settings"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["settings-root"].waitForExistence(timeout: 10))
  }

  func testCaptureSettingsSurfaces() {
    for appearance in ["light", "dark"] {
      var app = launch(appearance: appearance)
      openSettings(app)
      attach(app, name: "p11-settings-\(appearance)")

      app.buttons["Diagnostics"].tap()
      app.buttons["settings-diagnostics-collect"].tap()
      XCTAssertTrue(app.staticTexts["settings-diagnostics-report"].waitForExistence(timeout: 10))
      attach(app, name: "p11-diagnostics-\(appearance)")
      app.navigationBars["Diagnostics"].buttons["Settings"].tap()

      app.buttons["Welcome"].tap()
      XCTAssertTrue(app.descendants(matching: .any)["settings-onboarding-title"].waitForExistence(timeout: 10))
      attach(app, name: "p11-onboarding-\(appearance)")
      app.navigationBars["Welcome"].buttons["Settings"].tap()

      app.buttons["settings-done"].tap()
      app.terminate()
      app = launch(appearance: appearance)
      let newSession = app.buttons["home-new-session"]
      XCTAssertTrue(newSession.waitForExistence(timeout: 10))
      newSession.tap()
      XCTAssertTrue(app.textViews["composer-field"].waitForExistence(timeout: 10))
      app.buttons["composer-model"].tap()
      XCTAssertTrue(app.buttons["composer-model-openai/gpt-5.4"].waitForExistence(timeout: 15))
      attach(app, name: "p11-model-picker-\(appearance)")
      app.navigationBars["Model"].buttons["Done"].tap()

      app.buttons["composer-project-folder"].tap()
      XCTAssertTrue(app.buttons["folder-/work/opencode/Sources"].waitForExistence(timeout: 10))
      attach(app, name: "p11-folder-browser-\(appearance)")
      app.buttons["folder-cancel"].tap()
      app.buttons["session-done"].tap()
      app.terminate()
    }
  }

  private func attach(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
