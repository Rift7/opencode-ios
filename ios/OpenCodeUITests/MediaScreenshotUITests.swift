import XCTest

/// P10 surfaces. Everything on screen is deterministic fixture data with no personal information.
@MainActor
final class MediaScreenshotUITests: XCTestCase {
  private var browserServer: BrowserFixtureServer?

  override func setUp() {
    continueAfterFailure = false
  }

  override func tearDown() {
    browserServer?.stop()
    browserServer = nil
  }

  func testCaptureMediaSurfaces() {
    capture(style: "light", suffix: "")
    capture(style: "dark", suffix: "-dark")
  }

  private func capture(style: String, suffix: String) {
    let server = try? BrowserFixtureServer()
    browserServer = server
    var environment = ["OPENCODE_UI_TEST_CLIPBOARD_IMAGE": "1"]
    if let server { environment["OPENCODE_UI_TEST_BROWSER_URL"] = server.documentURL }
    let app = launch(
      style: style,
      extraArguments: ["-uiTestInAppBrowser", "-uiTestBrowserLoopback"],
      environment: environment
    )
    attach(app, name: "p10-transcript-media\(suffix)")

    app.buttons["transcript-image-media-image-1"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["media-viewer"].waitForExistence(timeout: 10))
    attach(app, name: "p10-image-viewer\(suffix)")
    app.buttons["media-viewer-close"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["media-viewer"].waitForNonExistence(timeout: 10))

    app.buttons["transcript-file-media-file-1"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["file-viewer"].waitForExistence(timeout: 10))
    attach(app, name: "p10-file-viewer\(suffix)")
    app.buttons["file-viewer-close"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["file-viewer"].waitForNonExistence(timeout: 10))

    let group = app.buttons["group-media-tool-images"]
    if group.waitForExistence(timeout: 5) {
      group.tap()
      app.buttons["tool-image-tool-image-1"].tap()
      XCTAssertTrue(app.descendants(matching: .any)["media-viewer"].waitForExistence(timeout: 10))
      attach(app, name: "p10-tool-mosaic\(suffix)")
      app.buttons["media-viewer-close"].tap()
      XCTAssertTrue(app.descendants(matching: .any)["media-viewer"].waitForNonExistence(timeout: 10))
    }

    let link = app.links["Open the docs"]
    if link.waitForExistence(timeout: 5) {
      link.tap()
      app.buttons["transcript-link-open"].firstMatch.tap()
      XCTAssertTrue(app.descendants(matching: .any)["browser"].waitForExistence(timeout: 10))
      XCTAssertTrue(app.staticTexts["Local fixture"].waitForExistence(timeout: 15))
      attach(app, name: "p10-browser\(suffix)")
      app.buttons["browser-close"].tap()
    }

    app.buttons["composer-add-attachment"].tap()
    app.buttons["Paste"].tap()
    let chip = app.buttons.containing(
      NSPredicate(format: "identifier BEGINSWITH %@", "composer-attachment-")
    ).firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 15))
    attach(app, name: "p10-composer-attachment\(suffix)")
    chip.tap()
    XCTAssertTrue(app.buttons["Annotate"].waitForExistence(timeout: 10))
    attach(app, name: "p10-attachment-preview\(suffix)")
    app.buttons["Annotate"].tap()
    XCTAssertTrue(app.navigationBars["Draw on Image"].waitForExistence(timeout: 10))
    attach(app, name: "p10-annotation\(suffix)")
    app.terminate()
  }

  private func launch(
    style: String,
    extraArguments: [String],
    environment: [String: String]
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-uiTesting", "-uiTestResetDrafts", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ] + extraArguments
    app.launchEnvironment = [
      "OPENCODE_UI_TEST_FIXTURE": "connected-media",
      "OPENCODE_UI_TEST_APPEARANCE": style,
    ].merging(environment) { $1 }
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 30))
    app.buttons["home-drawer-button"].tap()
    let row = app.buttons["drawer-session-row-alpha"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-session"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.textViews["composer-field"].waitForExistence(timeout: 10))
    return app
  }

  private func attach(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
