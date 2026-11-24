import XCTest

/// Model, agent, autocomplete/mention and remote folder journeys against the deterministic fixture.
@MainActor
final class ComposerContextUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  private func launch(mode: String = "connected-composer") -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-uiTesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
      "-uiTestResetSettings", "-uiTestResetDrafts",
    ]
    app.launchEnvironment = [
      "OPENCODE_UI_TEST_FIXTURE": mode,
      "OPENCODE_UI_TEST_APPEARANCE": "light",
    ]
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 30))
    return app
  }

  private func newSession(_ app: XCUIApplication) -> XCUIElement {
    app.buttons["home-new-session"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-session"].waitForExistence(timeout: 10))
    let field = app.textViews["composer-field"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    return field
  }

  func testModelAgentAndMentionSelection() {
    let app = launch()
    let field = newSession(app)

    app.buttons["composer-model"].tap()
    let model = app.buttons["composer-model-openai/gpt-5.4"]
    if !model.waitForExistence(timeout: 30) {
      print("MODEL HIERARCHY", app.debugDescription)
    }
    XCTAssertTrue(model.exists)
    model.tap()
    app.navigationBars["Model"].buttons["Done"].tap()
    let modelLabel = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label CONTAINS %@", "GPT-5.4"),
      object: app.buttons["composer-model"]
    )
    XCTAssertEqual(XCTWaiter().wait(for: [modelLabel], timeout: 15), .completed)

    app.buttons["composer-agent"].tap()
    let plan = app.buttons["composer-agent-plan"]
    XCTAssertTrue(plan.waitForExistence(timeout: 20))
    plan.tap()

    field.tap()
    field.typeText("@rev")
    let suggestion = app.buttons["composer-suggestion-skill:review"]
    XCTAssertTrue(suggestion.waitForExistence(timeout: 25))
    suggestion.tap()
    XCTAssertTrue(app.descendants(matching: .any)["composer-chip-skill:review"].waitForExistence(timeout: 10))

    let send = app.buttons["composer-send"]
    XCTAssertTrue(send.isEnabled)
    send.tap()
    XCTAssertTrue(app.staticTexts["@review"].waitForExistence(timeout: 10))
  }

  func testFolderBrowseSelectionAndCancelKeepTheDraft() {
    let app = launch()
    let field = newSession(app)
    field.tap()
    field.typeText("Keep this draft")

    let folder = app.buttons["composer-project-folder"]
    XCTAssertTrue(folder.waitForExistence(timeout: 10))
    folder.tap()
    XCTAssertTrue(app.buttons["folder-/work/opencode/Sources"].waitForExistence(timeout: 10))
    app.buttons["folder-/work/opencode/Sources"].tap()
    XCTAssertTrue(app.navigationBars["Sources"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["folder-select"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["folder-select"].isEnabled)
    app.buttons["folder-select"].tap()
    Thread.sleep(forTimeInterval: 1)

    let label = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label CONTAINS %@", "Sources"),
      object: app.buttons["composer-project-folder"]
    )
    XCTAssertEqual(XCTWaiter().wait(for: [label], timeout: 10), .completed)
    XCTAssertTrue((field.value as? String)?.contains("Keep this draft") == true)

    app.buttons["composer-project-folder"].tap()
    XCTAssertTrue(app.buttons["folder-cancel"].waitForExistence(timeout: 10))
    app.buttons["folder-cancel"].tap()
    XCTAssertTrue((field.value as? String)?.contains("Keep this draft") == true)
  }
}
