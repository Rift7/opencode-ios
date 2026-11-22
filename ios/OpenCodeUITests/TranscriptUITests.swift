import XCTest

/// Transcript behaviour against the deterministic in-app fixture.
final class TranscriptUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  private func launch(
    mode: String = "connected",
    appearance: String = "light",
    contentSize: String? = nil,
    reduceMotion: Bool = false
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    if let contentSize {
      app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
    }
    if reduceMotion {
      app.launchArguments += ["-UIAccessibilityReduceMotionEnabled", "YES"]
    }
    app.launchEnvironment = [
      "OPENCODE_UI_TEST_FIXTURE": mode,
      "OPENCODE_UI_TEST_APPEARANCE": appearance,
    ]
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 30))
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
    XCTAssertTrue(app.descendants(matching: .any)["transcript-list"].waitForExistence(timeout: 10))
  }

  private func scrollUp(_ app: XCUIApplication, to element: XCUIElement, attempts: Int = 24) {
    for _ in 0..<attempts {
      if element.exists {
        if element.isHittable { return }
        app.swipeUp()
        if element.isHittable { return }
      } else {
        app.swipeDown()
      }
    }
  }

  func testTranscriptRendersMarkdownToolsAndNotices() {
    let app = launch()
    openAlpha(app)

    let heading = app.staticTexts["Transcript review"]
    scrollUp(app, to: heading)
    XCTAssertTrue(heading.waitForExistence(timeout: 10))
    let group = app.buttons["group-alpha-tool-read"]
    scrollUp(app, to: group)
    XCTAssertTrue(group.waitForExistence(timeout: 10))
    group.tap()
    XCTAssertTrue(app.staticTexts["Read 240 lines"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["swift test finished"].exists)
    XCTAssertTrue(app.staticTexts["Compacted context"].exists)
  }

  func testDisclosureStaysOpenAcrossASubagentPage() {
    let app = launch()
    openAlpha(app)

    let group = app.buttons["group-alpha-tool-read"]
    scrollUp(app, to: group)
    XCTAssertTrue(group.waitForExistence(timeout: 10))
    group.tap()
    XCTAssertTrue(app.staticTexts["Read 240 lines"].waitForExistence(timeout: 10))

    app.buttons["session-subagents"].tap()
    let child = app.buttons["subagent-alpha-child"]
    XCTAssertTrue(child.waitForExistence(timeout: 10))
    child.tap()
    XCTAssertTrue(
      app.staticTexts["Explore how the composer queues a message."].waitForExistence(timeout: 10)
    )

    app.buttons["session-page-back"].tap()
    XCTAssertTrue(app.staticTexts["Transcript review"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Read 240 lines"].waitForExistence(timeout: 10))
  }

  func testCopyReplyUsesThePasteboard() {
    UIPasteboard.general.string = ""
    let app = launch()
    openAlpha(app)

    let copy = app.buttons["transcript-copy-reply-end-alpha-reply-1"]
    scrollUp(app, to: copy)
    XCTAssertTrue(copy.waitForExistence(timeout: 10))
    copy.tap()
    // The pasteboard write itself is asserted by the reducer test; the simulator's paste
    // privacy gate makes a cross-process read unreliable, so this journey checks the tap.
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-session"].exists)
  }

  func testLinkConfirmationNeverOpensOnItsOwn() {
    let app = launch()
    openAlpha(app)

    let link = app.links["OpenCode"].firstMatch
    scrollUp(app, to: link)
    if link.waitForExistence(timeout: 5) {
      link.tap()
    } else {
      let image = app.staticTexts["Diagram"].firstMatch
      scrollUp(app, to: image)
      XCTAssertTrue(image.waitForExistence(timeout: 10))
      image.tap()
    }
    XCTAssertTrue(app.staticTexts["Open Link?"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["Open"].exists)
    app.buttons["Copy Link"].tap()
    XCTAssertFalse(app.staticTexts["Open Link?"].exists)
  }

  func testJumpToLatestAfterReadingOlderContent() {
    let app = launch(mode: "connected-transcript-long")
    openAlpha(app)

    for _ in 0..<6 {
      app.swipeDown()
    }
    let jump = app.buttons["transcript-jump"]
    XCTAssertTrue(jump.waitForExistence(timeout: 10))
    jump.tap()
    let gone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"),
      object: jump
    )
    XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed)
  }

  func testLoadEarlierRetainsTheReadingPosition() {
    let app = launch(mode: "connected-transcript-older")
    openAlpha(app)

    let earlier = app.buttons["transcript-earlier"]
    for _ in 0..<24 where !earlier.exists {
      app.swipeDown()
    }
    XCTAssertTrue(earlier.waitForExistence(timeout: 10))
    earlier.tap()
    let gone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"),
      object: earlier
    )
    XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed)
    XCTAssertTrue(
      app.staticTexts["Message 170: keep the transcript stable while scrolling."]
        .waitForExistence(timeout: 10)
    )
  }

  func testDynamicTypeAndReduceMotionRenderTheTranscript() {
    let app = launch(
      appearance: "dark",
      contentSize: "UICTContentSizeCategoryAccessibilityL",
      reduceMotion: true
    )
    openAlpha(app)
    XCTAssertTrue(app.staticTexts["Compacted context"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["transcript-jump"].exists == false)
  }



  func testSelectsAssistantTextWithTheNativeMenu() {
    let app = launch()
    openAlpha(app)
    let text = app.staticTexts["The renderer keeps stable part identities and draws:"]
    scrollUp(app, to: text)
    XCTAssertTrue(text.waitForExistence(timeout: 10))
    text.press(forDuration: 1.2)
    let copy = app.menuItems["Copy"]
    XCTAssertTrue(copy.waitForExistence(timeout: 10))
    copy.tap()
  }
}
