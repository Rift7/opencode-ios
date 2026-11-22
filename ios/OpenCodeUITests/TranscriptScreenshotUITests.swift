import XCTest

/// Captures the P8 transcript surfaces for review. Everything on screen is synthetic fixture data.
final class TranscriptScreenshotUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testCaptureTranscriptSurfaces() {
    capture(appearance: "light", suffix: "")
    capture(appearance: "dark", suffix: "-dark")
  }

  private func capture(appearance: String, suffix: String) {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launchEnvironment = [
      "OPENCODE_UI_TEST_FIXTURE": "connected",
      "OPENCODE_UI_TEST_APPEARANCE": appearance,
    ]
    app.launch()

    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 30))
    app.buttons["home-drawer-button"].tap()
    let row = app.buttons["drawer-session-row-alpha"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.tap()
    XCTAssertTrue(app.descendants(matching: .any)["transcript-list"].waitForExistence(timeout: 15))
    attach(app, name: "p8-transcript\(suffix)")

    let group = app.buttons["group-alpha-tool-read"]
    for _ in 0..<24 where !group.exists || !group.isHittable {
      app.swipeDown()
    }
    XCTAssertTrue(group.waitForExistence(timeout: 10))
    XCTAssertTrue(group.isHittable)
    group.tap()
    attach(app, name: "p8-transcript-tools\(suffix)")

    app.terminate()

    let long = XCUIApplication()
    long.launchArguments = ["-uiTesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    long.launchEnvironment = [
      "OPENCODE_UI_TEST_FIXTURE": "connected-transcript-long",
      "OPENCODE_UI_TEST_APPEARANCE": appearance,
    ]
    long.launch()
    XCTAssertTrue(long.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 30))
    long.buttons["home-drawer-button"].tap()
    let longRow = long.buttons["drawer-session-row-alpha"]
    XCTAssertTrue(longRow.waitForExistence(timeout: 10))
    longRow.tap()
    XCTAssertTrue(long.descendants(matching: .any)["transcript-list"].waitForExistence(timeout: 15))
    for _ in 0..<3 {
      long.swipeDown()
    }
    if long.buttons["transcript-jump"].waitForExistence(timeout: 10) {
      attach(long, name: "p8-transcript-jump\(suffix)")
    }
    long.terminate()
  }

  private func attach(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
