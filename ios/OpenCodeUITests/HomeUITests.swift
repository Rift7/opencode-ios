import XCTest

/// Home, the drawer, server switching and Catch Up against the deterministic in-app fixture.
final class HomeUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launchEnvironment = ["OPENCODE_UI_TEST_FIXTURE": "connected"]
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 15))
    return app
  }

  private func openDrawer(_ app: XCUIApplication) {
    let button = app.buttons["home-drawer-button"]
    XCTAssertTrue(button.waitForExistence(timeout: 10))
    button.tap()
    XCTAssertTrue(app.descendants(matching: .any)["drawer"].waitForExistence(timeout: 10))
  }

  func testDrawerSearchOpensASessionSelection() {
    let app = launch()
    openDrawer(app)

    let search = app.textFields["drawer-search"]
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.tap()
    search.typeText("Alpha")

    let row = app.buttons["drawer-session-row-alpha"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["drawer-session-row-beta"].exists)
    row.tap()

    XCTAssertTrue(app.descendants(matching: .any)["root-phase-session"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Alpha release notes"].exists)
    XCTAssertTrue(app.staticTexts["Can you review the transcript implementation?"].waitForExistence(timeout: 10))
    app.buttons["session-done"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 10))
  }

  func testMarkAllReadFromTheCatchUpMenu() {
    let app = launch()
    openDrawer(app)
    let more = app.buttons["drawer-more"]
    XCTAssertTrue(more.waitForExistence(timeout: 10))
    more.tap()
    let markAll = app.buttons["Mark All as Read"]
    XCTAssertTrue(markAll.waitForExistence(timeout: 10))
    markAll.tap()
    let catchUp = app.buttons["drawer-catch-up"]
    XCTAssertTrue(catchUp.waitForExistence(timeout: 10))
    let disabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == false"),
      object: catchUp
    )
    XCTAssertEqual(XCTWaiter().wait(for: [disabled], timeout: 10), .completed)
  }

  func testSwitchingSavedServersLoadsTheOtherServer() {
    let app = launch()

    let serverButton = app.buttons["home-server-button"]
    XCTAssertTrue(serverButton.waitForExistence(timeout: 10))
    serverButton.tap()

    let second = app.buttons["server-switch-Second"]
    XCTAssertTrue(second.waitForExistence(timeout: 10))
    second.tap()

    XCTAssertTrue(app.staticTexts["Second"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["Second server session"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.staticTexts["Alpha release notes"].exists)
  }

  func testCatchUpMarksKeepsAndUndoes() {
    let app = launch()
    openDrawer(app)

    let catchUp = app.buttons["drawer-catch-up"]
    XCTAssertTrue(catchUp.waitForExistence(timeout: 10))
    catchUp.tap()

    XCTAssertTrue(app.descendants(matching: .any)["catch-up-card"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Alpha release notes"].exists)

    app.buttons["catch-up-mark-read"].tap()
    XCTAssertTrue(app.staticTexts["Gamma design"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["catch-up-undo"].waitForExistence(timeout: 10))

    app.buttons["catch-up-undo"].tap()
    XCTAssertTrue(app.staticTexts["Alpha release notes"].waitForExistence(timeout: 10))

    app.buttons["catch-up-mark-read"].tap()
    XCTAssertTrue(app.staticTexts["Gamma design"].waitForExistence(timeout: 10))

    app.buttons["catch-up-keep-unread"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["drawer"].waitForExistence(timeout: 10))
    let allCaughtUp = app.buttons["drawer-all-caught-up"]
    XCTAssertTrue(allCaughtUp.waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["drawer-catch-up"].exists)
  }


  func testWhatsNewMarksSeenWhenClosed() {
    let app = launch()
    openDrawer(app)

    let whatsNew = app.buttons["drawer-whats-new"]
    XCTAssertTrue(whatsNew.waitForExistence(timeout: 10))
    whatsNew.tap()
    XCTAssertTrue(app.descendants(matching: .any)["whats-new-list"].waitForExistence(timeout: 10))
    app.buttons["whats-new-done"].tap()

    XCTAssertTrue(app.descendants(matching: .any)["drawer"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["drawer-whats-new"].exists)
  }

  func testLargeDynamicTypeKeepsTheDrawerUsable() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-uiTesting",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_US",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
    ]
    app.launchEnvironment = ["OPENCODE_UI_TEST_FIXTURE": "connected"]
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 15))
    openDrawer(app)
    XCTAssertTrue(app.textFields["drawer-search"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["drawer-session-row-alpha"].waitForExistence(timeout: 10))
  }

  func testSearchRowAccessibilityLabelAndKeyboardDismissal() {
    let app = launch()
    openDrawer(app)
    let search = app.textFields["drawer-search"]
    search.tap()
    search.typeText("Alpha")
    let row = app.buttons["drawer-session-row-alpha"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    XCTAssertTrue(row.label.contains("Alpha release notes"))
    XCTAssertTrue(row.label.contains("Unread"))

    app.buttons["drawer-done"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.keyboards.firstMatch.exists)
  }

}
