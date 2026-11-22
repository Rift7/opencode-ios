import XCTest

/// Reproducible scroll traces over synthetic transcripts. Simulator measurements only; the
/// printed probe line is the evidence recorded in STATUS.md.
final class TranscriptScrollTraceUITests: XCTestCase {
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

  func testLongTranscriptScroll() {
    let app = open(mode: "connected-transcript-long")
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
      print("TRANSCRIPT-SCROLL-TRACE \(app.staticTexts["transcript-frame-probe"].label)")
    }
  }

  func testStreamingTranscriptScroll() {
    let app = open(mode: "connected-transcript-stream")
    sleep(1)
    let options = XCTMeasureOptions()
    options.iterationCount = 3
    measure(
      metrics: [XCTOSSignpostMetric.scrollDecelerationMetric, XCTMemoryMetric()],
      options: options
    ) {
      app.swipeUp(velocity: .fast)
      app.swipeDown(velocity: .fast)
      sleep(1)
      print("TRANSCRIPT-STREAM-TRACE \(app.staticTexts["transcript-frame-probe"].label)")
    }
  }
}
