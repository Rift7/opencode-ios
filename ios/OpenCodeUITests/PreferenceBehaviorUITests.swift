import XCTest

/// Preferences must change behaviour, not only survive storage. These journeys compare the default
/// and enabled behaviour across a relaunch on the deterministic fixture.
@MainActor
final class PreferenceBehaviorUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  private func launch(
    mode: String = "connected-composer",
    resetSettings: Bool
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-uiTesting", "-uiTestResetDrafts", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    if resetSettings { app.launchArguments += ["-uiTestResetSettings"] }
    app.launchEnvironment = [
      "OPENCODE_UI_TEST_FIXTURE": mode,
      "OPENCODE_UI_TEST_APPEARANCE": "light",
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

  private func setSwitch(_ app: XCUIApplication, id: String, on: Bool) {
    let toggle = app.switches[id]
    XCTAssertTrue(toggle.waitForExistence(timeout: 10))
    if (toggle.value as? String) != (on ? "1" : "0") {
      toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }
    let predicate = NSPredicate(format: "value == %@", on ? "1" : "0")
    XCTAssertEqual(
      XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: toggle)], timeout: 10),
      .completed
    )
  }

  private func openNewSession(_ app: XCUIApplication) -> XCUIElement {
    app.buttons["home-new-session"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-session"].waitForExistence(timeout: 10))
    let field = app.textViews["composer-field"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    return field
  }

  private func openSession(_ app: XCUIApplication) {
    app.buttons["home-drawer-button"].tap()
    let row = app.buttons["drawer-session-row-alpha"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-session"].waitForExistence(timeout: 10))
  }

  private func openFile(_ app: XCUIApplication) {
    let file = app.buttons["transcript-file-media-file-1"]
    XCTAssertTrue(file.waitForExistence(timeout: 10))
    file.tap()
    XCTAssertTrue(app.descendants(matching: .any)["file-viewer"].waitForExistence(timeout: 10))
  }

  func testReturnSendsChangesComposerBehaviourAcrossRelaunch() {
    var app = launch(resetSettings: true)
    var field = openNewSession(app)
    field.tap()
    field.typeText("Line one\nLine two")
    XCTAssertTrue((field.value as? String)?.contains("Line one\nLine two") == true)
    app.buttons["session-done"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 10))

    openSettings(app)
    setSwitch(app, id: "settings-return-sends", on: true)
    app.buttons["settings-done"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 10))
    app.terminate()

    app = launch(resetSettings: false)
    field = openNewSession(app)
    field.tap()
    field.typeText("Sent by Return")
    app.typeText("\n")
    XCTAssertTrue(app.staticTexts["Sent by Return"].waitForExistence(timeout: 10))
    XCTAssertFalse((field.value as? String)?.contains("Sent by Return") == true)
  }

  func testReturnSendsAnswersARequestWithoutSendingChat() {
    var app = launch(resetSettings: true)
    openSettings(app)
    setSwitch(app, id: "settings-return-sends", on: true)
    app.buttons["settings-done"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 10))
    app.terminate()

    app = launch(mode: "connected-composer-question", resetSettings: false)
    openSession(app)
    XCTAssertTrue(app.descendants(matching: .any)["request-answer-bar"].waitForExistence(timeout: 10))
    let field = app.textViews["composer-field"]
    field.tap()
    field.typeText("staging")
    app.typeText("\n")
    XCTAssertFalse(app.staticTexts["staging"].waitForExistence(timeout: 3))
    XCTAssertTrue(
      app.descendants(matching: .any)["request-answer-bar"].waitForNonExistence(timeout: 10)
    )
  }

  func testWrapLinesChangesFileViewerBehaviourAcrossRelaunch() {
    var app = launch(mode: "connected-media", resetSettings: true)
    openSession(app)
    openFile(app)
    XCTAssertTrue(app.scrollViews["file-viewer-code-unwrapped"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.scrollViews["file-viewer-code-wrapped"].exists)
    app.buttons["file-viewer-wrap-lines"].tap()
    XCTAssertTrue(app.scrollViews["file-viewer-code-wrapped"].waitForExistence(timeout: 10))
    app.buttons["file-viewer-wrap-lines"].tap()
    XCTAssertTrue(app.scrollViews["file-viewer-code-unwrapped"].waitForExistence(timeout: 10))
    app.buttons["file-viewer-close"].tap()
    app.buttons["session-done"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 10))

    openSettings(app)
    setSwitch(app, id: "settings-wrap-lines", on: true)
    app.buttons["settings-done"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 10))
    app.terminate()

    app = launch(mode: "connected-media", resetSettings: false)
    openSession(app)
    openFile(app)
    XCTAssertTrue(app.scrollViews["file-viewer-code-wrapped"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.scrollViews["file-viewer-code-unwrapped"].exists)
  }
}
