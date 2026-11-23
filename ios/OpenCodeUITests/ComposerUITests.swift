import XCTest

/// Composer, draft, send, queue, request-dock and quote journeys against the deterministic fixture.
@MainActor
final class ComposerUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  private func launch(
    mode: String = "connected-composer",
    resetDrafts: Bool = true,
    appearance: String = "light",
    contentSize: String? = nil
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    if resetDrafts { app.launchArguments += ["-uiTestResetDrafts"] }
    if let contentSize {
      app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
    }
    app.launchEnvironment = [
      "OPENCODE_UI_TEST_FIXTURE": mode,
      "OPENCODE_UI_TEST_APPEARANCE": appearance,
    ]
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 30))
    return app
  }

  private func openSession(_ app: XCUIApplication, id: String = "alpha") {
    let drawer = app.buttons["home-drawer-button"]
    XCTAssertTrue(drawer.waitForExistence(timeout: 10))
    drawer.tap()
    let row = app.buttons["drawer-session-row-\(id)"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-session"].waitForExistence(timeout: 10))
    let field = app.textViews["composer-field"]
    if !field.waitForExistence(timeout: 10) {
      print(app.debugDescription)
    }
    XCTAssertTrue(field.exists)
  }

  private func openNewSession(_ app: XCUIApplication) -> XCUIElement {
    let button = app.buttons["home-new-session"]
    XCTAssertTrue(button.waitForExistence(timeout: 10))
    button.tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-session"].waitForExistence(timeout: 10))
    let field = app.textViews["composer-field"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    return field
  }

  private func scrollUp(_ app: XCUIApplication, to element: XCUIElement, attempts: Int = 20) {
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

  private func waitForValue(_ element: XCUIElement, contains text: String, timeout: TimeInterval = 10) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let value = element.value as? String, value.contains(text) { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return (element.value as? String)?.contains(text) == true
  }

  func testNewSessionComposeSendAndSettlement() {
    let app = launch()
    let field = openNewSession(app)
    field.tap()
    field.typeText("Hello fixture")
    let send = app.buttons["composer-send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    send.tap()
    XCTAssertTrue(app.staticTexts["Hello fixture"].waitForExistence(timeout: 10))
    XCTAssertFalse((field.value as? String)?.contains("Hello fixture") == true)
  }

  func testRelaunchRestoresAnUnsentDraft() {
    var app = launch()
    openSession(app)
    let field = app.textViews["composer-field"]
    field.tap()
    field.typeText("Draft across launches")
    XCTAssertTrue(waitForValue(field, contains: "Draft across launches"))
    app.buttons["session-done"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 10))
    Thread.sleep(forTimeInterval: 1.0)
    app.terminate()

    app = launch(resetDrafts: false)
    openSession(app)
    let restored = app.textViews["composer-field"]
    XCTAssertTrue(waitForValue(restored, contains: "Draft across launches"))
  }

  func testFailedSendKeepsTheDraftAndRetries() {
    let app = launch(mode: "connected-composer-fail")
    openSession(app)
    let field = app.textViews["composer-field"]
    field.tap()
    field.typeText("Retry me")
    app.buttons["composer-send"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["composer-problem"].waitForExistence(timeout: 10))
    XCTAssertTrue(waitForValue(field, contains: "Retry me"))
    app.buttons["composer-send"].tap()
    XCTAssertTrue(app.staticTexts["Retry me"].waitForExistence(timeout: 10))
  }

  func testSwitchingSessionsKeepsSeparateDrafts() {
    let app = launch()
    openSession(app, id: "alpha")
    let alpha = app.textViews["composer-field"]
    alpha.tap()
    alpha.typeText("Alpha draft")
    Thread.sleep(forTimeInterval: 0.8)
    app.buttons["session-done"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 10))

    openSession(app, id: "beta")
    let beta = app.textViews["composer-field"]
    XCTAssertFalse((beta.value as? String)?.contains("Alpha draft") == true)
    beta.tap()
    beta.typeText("Beta draft")
    Thread.sleep(forTimeInterval: 0.8)
    app.buttons["session-done"].tap()

    openSession(app, id: "alpha")
    XCTAssertTrue(waitForValue(app.textViews["composer-field"], contains: "Alpha draft"))
  }

  func testSendWhileRunningShowsQueuedInputsAndMovesDelivery() {
    let app = launch(mode: "connected-composer-running")
    openSession(app)
    XCTAssertTrue(app.staticTexts["session-working"].waitForExistence(timeout: 10))
    let field = app.textViews["composer-field"]
    field.tap()
    field.typeText("Steer from UI")
    app.buttons["composer-send"].tap()

    let pill = app.buttons["composer-queued-pill"]
    XCTAssertTrue(pill.waitForExistence(timeout: 10))
    pill.tap()
    XCTAssertTrue(app.descendants(matching: .any)["queued-messages-sheet"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Steer from UI"].waitForExistence(timeout: 10))
    let move = app.buttons["Move to Queue"].firstMatch
    if move.exists {
      move.tap()
      XCTAssertTrue(app.staticTexts["Queued"].waitForExistence(timeout: 10))
    }
    app.buttons["queued-messages-close"].tap()
  }

  func testRequestDockAnswersWithoutSendingChat() {
    let app = launch(mode: "connected-composer-question")
    openSession(app)
    XCTAssertTrue(app.descendants(matching: .any)["request-dock"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.descendants(matching: .any)["request-answer-bar"].exists)
    let field = app.textViews["composer-field"]
    field.tap()
    field.typeText("staging\n")
    XCTAssertFalse(app.staticTexts["staging"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.textViews["composer-field"].waitForExistence(timeout: 10))
  }

  func testSelectedReplyTextBecomesAComposerQuote() {
    let app = launch()
    openSession(app)
    let quote = app.buttons["transcript-quote-reply-end-alpha-reply-1"]
    scrollUp(app, to: quote)
    XCTAssertTrue(quote.waitForExistence(timeout: 10))
    quote.tap()
    XCTAssertTrue(app.descendants(matching: .any)["quote-selection-sheet"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.textViews["quote-selection-text"].waitForExistence(timeout: 10))
    app.buttons["quote-selection-confirm"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["composer-quote-chips"].waitForExistence(timeout: 10))
  }

  func testMultilineComposerSurvivesDynamicTypeDarkModeAndKeyboardDismissal() {
    let app = launch(
      appearance: "dark",
      contentSize: "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"
    )
    openSession(app)
    let field = app.textViews["composer-field"]
    field.tap()
    field.typeText("A larger multiline message that wraps in the composer")
    XCTAssertTrue(waitForValue(field, contains: "A larger multiline"))
    app.swipeDown()
    XCTAssertTrue(field.exists)
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-session"].exists)
  }

  func testTypingDoesNotReparseTheWholeTranscript() {
    let app = launch(mode: "connected-composer-long")
    openSession(app)
    let parse = app.staticTexts["markdown-parse-count"]
    let entries = app.staticTexts["transcript-entry-count"]
    XCTAssertTrue(parse.waitForExistence(timeout: 10))
    let parseBefore = parse.label
    let entriesBefore = entries.label

    let field = app.textViews["composer-field"]
    field.tap()
    let started = ContinuousClock.now
    field.typeText("typing while a long transcript stays still")
    let elapsed = ContinuousClock.now - started
    Thread.sleep(forTimeInterval: 0.5)

    XCTAssertEqual(parse.label, parseBefore)
    XCTAssertEqual(entries.label, entriesBefore)
    let typingProbe = app.staticTexts["composer-typing-probe"]
    print("TYPING_LATENCY_MS", elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    print("TYPING_MAIN_TURN_PROBE", typingProbe.exists ? typingProbe.label : "missing")
    let attachment = XCTAttachment(string: "typing elapsed \(elapsed)")
    attachment.name = "composer-typing-latency"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testTypingDuringStreamingKeepsTheComposerResponsive() {
    let app = launch(mode: "connected-composer-stream")
    openSession(app)
    let field = app.textViews["composer-field"]
    field.tap()
    let started = ContinuousClock.now
    field.typeText("typing during streaming")
    let elapsed = ContinuousClock.now - started
    XCTAssertTrue(waitForValue(field, contains: "typing during streaming"))
    let typingProbe = app.staticTexts["composer-typing-probe"]
    print("STREAMING_TYPING_LATENCY_MS", elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    print("STREAMING_TYPING_MAIN_TURN_PROBE", typingProbe.exists ? typingProbe.label : "missing")
    let attachment = XCTAttachment(string: "streaming typing elapsed \(elapsed)")
    attachment.name = "composer-streaming-typing-latency"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
