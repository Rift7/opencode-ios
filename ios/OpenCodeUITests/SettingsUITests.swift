import XCTest

/// Settings, experiments, diagnostics, onboarding, header editing and injected QR pairing. No
/// camera, keychain or network is used.
@MainActor
final class SettingsUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  private func launch(
    resetSettings: Bool = true,
    pairingPayload: String? = nil
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    if resetSettings { app.launchArguments += ["-uiTestResetSettings"] }
    if let pairingPayload {
      app.launchArguments += ["-uiTestPairingPayload", pairingPayload]
    }
    app.launchEnvironment = [
      "OPENCODE_UI_TEST_FIXTURE": "connected",
      "OPENCODE_UI_TEST_APPEARANCE": "light",
    ]
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 30))
    return app
  }

  private func waitForValue(_ element: XCUIElement, _ value: String) -> Bool {
    let predicate = NSPredicate(format: "value == %@", value)
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
      timeout: 10
    ) == .completed
  }

  private func openSettings(_ app: XCUIApplication) {
    let drawer = app.buttons["home-drawer-button"]
    XCTAssertTrue(drawer.waitForExistence(timeout: 10))
    drawer.tap()
    let gear = app.buttons["drawer-settings"]
    XCTAssertTrue(gear.waitForExistence(timeout: 10))
    gear.tap()
    XCTAssertTrue(app.descendants(matching: .any)["settings-root"].waitForExistence(timeout: 10))
  }

  func testPreferenceSurvivesRelaunch() {
    var app = launch()
    openSettings(app)
    let browser = app.switches["settings-in-app-browser"]
    XCTAssertTrue(browser.waitForExistence(timeout: 10))
    browser.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    XCTAssertTrue(waitForValue(browser, "1"))
    app.buttons["settings-done"].tap()

    app.terminate()
    app = launch(resetSettings: false)
    openSettings(app)
    XCTAssertTrue(app.switches["settings-in-app-browser"].waitForExistence(timeout: 10))
    XCTAssertTrue(waitForValue(app.switches["settings-in-app-browser"], "1"))
  }

  func testDiagnosticsCollectAndCopy() {
    let app = launch()
    openSettings(app)
    app.buttons["Diagnostics"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["settings-diagnostics-title"].waitForExistence(timeout: 10))
    app.buttons["settings-diagnostics-collect"].tap()
    XCTAssertTrue(app.staticTexts["settings-diagnostics-report"].waitForExistence(timeout: 10))
    app.buttons["settings-diagnostics-copy"].tap()
    XCTAssertTrue(app.staticTexts["Copied"].waitForExistence(timeout: 10))
  }

  func testOnboardingCompletesWithoutAServer() {
    let app = launch()
    openSettings(app)
    app.buttons["Welcome"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["settings-onboarding-title"].waitForExistence(timeout: 10))
    app.buttons["settings-onboarding-next"].tap()
    app.buttons["settings-onboarding-next"].tap()
    app.buttons["settings-onboarding-finish"].tap()
    XCTAssertTrue(app.staticTexts["You’re Ready"].waitForExistence(timeout: 10))
    app.buttons["Done"].tap()
  }

  func testServerHeaderEditKeepsTheServerUsable() {
    let app = launch()
    openSettings(app)
    app.buttons["settings-edit-server"].tap()
    XCTAssertTrue(app.textFields["settings-server-name"].waitForExistence(timeout: 10))
    app.buttons["settings-header-add"].tap()
    let name = app.textFields["settings-header-name-0"]
    XCTAssertTrue(name.waitForExistence(timeout: 10))
    name.tap()
    name.typeText("CF-Access-Client-Id")
    let value = app.textFields["settings-header-value-0"]
    value.tap()
    value.typeText("synthetic-id")
    app.buttons["settings-server-save"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Fixture"].exists)
  }

  func testInjectedQRShowsConfirmationExactlyOnce() {
    let payload = "opencode-ios://pair?code=Pair-123_xyz&url=https%3A%2F%2Fstudio.invalid"
    let app = launch(pairingPayload: payload)
    openSettings(app)
    app.buttons["settings-scan-server"].tap()
    let alert = app.alerts.firstMatch
    XCTAssertTrue(alert.waitForExistence(timeout: 10))
    XCTAssertTrue(alert.buttons["Pair"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["settings-scan-instruction"].exists)
  }
}
