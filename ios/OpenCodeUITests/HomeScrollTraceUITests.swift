import XCTest

/// A reproducible drawer scroll trace over a 300-session fixture. XCTest reports the measured
/// scroll-deceleration values; nothing here asserts a frame budget.
final class HomeScrollTraceUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testDrawerScrollDeceleration() {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launchEnvironment = ["OPENCODE_UI_TEST_FIXTURE": "connected-scroll"]
    app.launch()

    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 15))
    app.buttons["home-drawer-button"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["drawer"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["drawer-session-row-scroll-session-0"].waitForExistence(timeout: 15))

    let options = XCTMeasureOptions()
    options.iterationCount = 3
    measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric], options: options) {
      app.swipeUp(velocity: .fast)
      app.swipeUp(velocity: .fast)
      app.swipeDown(velocity: .fast)
      sleep(1)
      print("SCROLL-FRAME-TRACE \(app.staticTexts["scroll-frame-probe"].label)")
    }
  }
}
