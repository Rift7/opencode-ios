import XCTest

/// Simulator measurements for the media-heavy transcript and a large image. The printed probe lines
/// and XCTest metrics are the evidence recorded in STATUS.md; this is not a device claim.
final class MediaPerformanceUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  private func open(mode: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launchEnvironment = ["OPENCODE_UI_TEST_FIXTURE": mode]
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 30))
    app.buttons["home-drawer-button"].tap()
    let row = app.buttons["drawer-session-row-alpha"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.tap()
    XCTAssertTrue(app.descendants(matching: .any)["transcript-list"].waitForExistence(timeout: 15))
    return app
  }

  func testMediaHeavyTranscriptScroll() {
    let app = open(mode: "connected-media-long")
    let options = XCTMeasureOptions()
    options.iterationCount = 3
    measure(
      metrics: [XCTOSSignpostMetric.scrollDecelerationMetric, XCTMemoryMetric()],
      options: options
    ) {
      app.swipeUp(velocity: .fast)
      app.swipeUp(velocity: .fast)
      app.swipeDown(velocity: .fast)
      sleep(1)
      print("MEDIA-SCROLL-TRACE \(app.staticTexts["transcript-frame-probe"].label)")
    }
  }

  func testTypingWhileAnAttachmentIsImporting() {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-uiTestResetDrafts", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launchEnvironment = [
      "OPENCODE_UI_TEST_FIXTURE": "connected-media",
      "OPENCODE_UI_TEST_APPEARANCE": "light",
      "OPENCODE_UI_TEST_CLIPBOARD_IMAGE": "1",
    ]
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 30))
    app.buttons["home-drawer-button"].tap()
    let row = app.buttons["drawer-session-row-alpha"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.tap()
    XCTAssertTrue(app.textViews["composer-field"].waitForExistence(timeout: 10))
    app.buttons["composer-add-attachment"].tap()
    app.buttons["Paste"].tap()
    let chip = app.buttons.containing(
      NSPredicate(format: "identifier BEGINSWITH %@", "composer-attachment-")
    ).firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 15))
    let field = app.textViews["composer-field"]
    field.tap()
    field.typeText("Drafting while the attachment lands, then a second sentence with more words. ")
    sleep(1)
    print("MEDIA-TYPING-TRACE \(app.staticTexts["composer-typing-probe"].label)")
  }

  func testLargeImageViewerOpen() {
    let app = open(mode: "connected-media-large")
    let image = app.buttons["transcript-image-large-image"]
    XCTAssertTrue(image.waitForExistence(timeout: 15))
    let options = XCTMeasureOptions()
    options.iterationCount = 3
    measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
      app.buttons["transcript-image-large-image"].tap()
      XCTAssertTrue(app.descendants(matching: .any)["media-viewer"].waitForExistence(timeout: 10))
      app.buttons["media-viewer-close"].tap()
      XCTAssertTrue(app.descendants(matching: .any)["media-viewer"].waitForNonExistence(timeout: 10))
      XCTAssertTrue(app.buttons["transcript-image-large-image"].waitForExistence(timeout: 10))
    }
  }
}
