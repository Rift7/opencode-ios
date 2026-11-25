import XCTest

/// P10 media journeys against synthetic fixtures: transcript images, tool mosaics, server files,
/// the browser gate and composer attachments.
@MainActor
final class MediaUITests: XCTestCase {
  private var browserServer: BrowserFixtureServer?

  override func setUp() {
    continueAfterFailure = false
  }

  override func tearDown() {
    browserServer?.stop()
    browserServer = nil
  }

  private func launch(
    mode: String = "connected-media",
    appearance: String = "light",
    extraArguments: [String] = [],
    environment: [String: String] = [:],
    browserFixture: Bool = false
  ) -> XCUIApplication {
    let app = XCUIApplication()
    var arguments = extraArguments
    var environment = environment
    if browserFixture {
      let server = try? BrowserFixtureServer()
      browserServer = server
      arguments += ["-uiTestInAppBrowser", "-uiTestBrowserLoopback"]
      if let server { environment["OPENCODE_UI_TEST_BROWSER_URL"] = server.documentURL }
    }
    app.launchArguments = [
      "-uiTesting", "-uiTestResetDrafts", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ] + arguments
    app.launchEnvironment = [
      "OPENCODE_UI_TEST_FIXTURE": mode,
      "OPENCODE_UI_TEST_APPEARANCE": appearance,
    ].merging(environment) { $1 }
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 30))
    openAlpha(app)
    return app
  }

  private func openAlpha(_ app: XCUIApplication) {
    app.buttons["home-drawer-button"].tap()
    let row = app.buttons["drawer-session-row-alpha"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.tap()
    XCTAssertTrue(app.descendants(matching: .any)["root-phase-session"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.textViews["composer-field"].waitForExistence(timeout: 10))
  }

  func testTranscriptImageGalleryAndToolMosaic() {
    let app = launch()
    let image = app.buttons["transcript-image-media-image-1"]
    XCTAssertTrue(image.waitForExistence(timeout: 10))
    image.tap()
    XCTAssertTrue(app.descendants(matching: .any)["media-viewer"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Chart.png"].waitForExistence(timeout: 10))
    app.buttons["media-viewer-close"].tap()
    XCTAssertFalse(app.descendants(matching: .any)["media-viewer"].waitForExistence(timeout: 5))
    // Let the full-screen dismissal finish before the next transcript tap.
    Thread.sleep(forTimeInterval: 0.8)

    let group = app.buttons["group-media-tool-images"]
    XCTAssertTrue(group.waitForExistence(timeout: 10))
    // The P11 composer is taller (model/agent/mention chips), so the group can sit at the bottom
    // edge of the transcript viewport after a viewer closes.
    // Move the group clear of the composer's safe-area inset rather than trusting `isHittable`,
    // which can be true while the composer covers the row.
    app.scrollViews["transcript-list"].swipeUp()
    Thread.sleep(forTimeInterval: 0.4)
    for _ in 0..<3 where !group.isHittable {
      app.scrollViews["transcript-list"].swipeUp()
    }
    XCTAssertTrue(group.isHittable)
    group.tap()
    Thread.sleep(forTimeInterval: 0.8)
    let mosaicImage = app.buttons["tool-image-tool-image-1"]
    for _ in 0..<3 where !mosaicImage.exists {
      app.scrollViews["transcript-list"].swipeUp()
    }
    XCTAssertTrue(mosaicImage.waitForExistence(timeout: 10))
    mosaicImage.tap()
    XCTAssertTrue(app.descendants(matching: .any)["media-viewer"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Frame 1.png"].waitForExistence(timeout: 10))
    app.buttons["media-viewer-close"].tap()
  }

  func testServerFilePreview() {
    let app = launch()
    let file = app.buttons["transcript-file-media-file-1"]
    XCTAssertTrue(file.waitForExistence(timeout: 10))
    file.tap()
    XCTAssertTrue(app.descendants(matching: .any)["file-viewer"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["main.swift"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "let fixtureValue")).firstMatch.waitForExistence(timeout: 10))
    app.buttons["file-viewer-close"].tap()
    XCTAssertFalse(app.descendants(matching: .any)["file-viewer"].waitForExistence(timeout: 5))
  }

  func testBrowserGateOpensOnlyWithTheExperiment() {
    let app = launch(browserFixture: true)
    let link = app.links["Open the docs"]
    XCTAssertTrue(link.waitForExistence(timeout: 10))
    link.tap()
    XCTAssertTrue(app.buttons["transcript-link-open"].firstMatch.waitForExistence(timeout: 10))
    app.buttons["transcript-link-open"].firstMatch.tap()
    XCTAssertTrue(app.descendants(matching: .any)["browser"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Local fixture"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["browser-close"].waitForExistence(timeout: 10))
    app.buttons["browser-close"].tap()
    XCTAssertFalse(app.descendants(matching: .any)["browser"].waitForExistence(timeout: 5))
  }

  func testComposerPastePreviewAndRemove() {
    let app = launch(environment: ["OPENCODE_UI_TEST_CLIPBOARD_IMAGE": "1"])
    app.buttons["composer-add-attachment"].tap()
    let paste = app.buttons["Paste"]
    XCTAssertTrue(paste.waitForExistence(timeout: 10))
    paste.tap()
    let chip = app.buttons.containing(
      NSPredicate(format: "identifier BEGINSWITH %@", "composer-attachment-")
    ).firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 15))
    chip.tap()
    XCTAssertTrue(app.buttons["Annotate"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["composer-preview-remove"].waitForExistence(timeout: 10))
    app.buttons["composer-preview-remove"].tap()
    XCTAssertFalse(
      app.buttons.containing(
        NSPredicate(format: "identifier BEGINSWITH %@", "composer-attachment-")
      ).firstMatch.waitForExistence(timeout: 5)
    )
  }

  func testComposerSendsAPastedImage() {
    let app = launch(environment: ["OPENCODE_UI_TEST_CLIPBOARD_IMAGE": "1"])
    app.buttons["composer-add-attachment"].tap()
    app.buttons["Paste"].tap()
    let chip = app.buttons.containing(
      NSPredicate(format: "identifier BEGINSWITH %@", "composer-attachment-")
    ).firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 15))
    let field = app.textViews["composer-field"]
    field.tap()
    field.typeText("Look at this")
    app.buttons["composer-send"].tap()
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Look at this"))
        .firstMatch.waitForExistence(timeout: 15)
    )
  }

  func testAnnotationReturnsADrawingToTheComposer() {
    let app = launch(environment: ["OPENCODE_UI_TEST_CLIPBOARD_IMAGE": "1"])
    app.buttons["composer-add-attachment"].tap()
    app.buttons["Paste"].tap()
    let chip = app.buttons.containing(
      NSPredicate(format: "identifier BEGINSWITH %@", "composer-attachment-")
    ).firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 15))
    chip.tap()
    XCTAssertTrue(app.buttons["Annotate"].waitForExistence(timeout: 10))
    app.buttons["Annotate"].tap()
    XCTAssertTrue(app.navigationBars["Draw on Image"].waitForExistence(timeout: 10))
    let canvas = app.descendants(matching: .any).matching(identifier: "annotation-canvas").firstMatch
    if canvas.waitForExistence(timeout: 5) {
      let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
      let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.55))
      start.press(forDuration: 0.15, thenDragTo: end)
    } else {
      app.swipeRight()
    }
    XCTAssertTrue(app.buttons["annotation-add"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["annotation-add"].isEnabled)
    app.buttons["annotation-add"].tap()
    let chips = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "composer-attachment-")
    )
    XCTAssertTrue(chips.count >= 2)
  }

  func testPastedAttachmentSurvivesRelaunch() {
    let app = launch(environment: ["OPENCODE_UI_TEST_CLIPBOARD_IMAGE": "1"])
    app.buttons["composer-add-attachment"].tap()
    app.buttons["Paste"].tap()
    let chip = app.buttons.containing(
      NSPredicate(format: "identifier BEGINSWITH %@", "composer-attachment-")
    ).firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 15))
    let field = app.textViews["composer-field"]
    field.tap()
    field.typeText("Keep this")
    sleep(2)
    app.terminate()

    let relaunched = XCUIApplication()
    relaunched.launchArguments = ["-uiTesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    relaunched.launchEnvironment = [
      "OPENCODE_UI_TEST_FIXTURE": "connected-media",
      "OPENCODE_UI_TEST_APPEARANCE": "light",
      "OPENCODE_UI_TEST_CLIPBOARD_IMAGE": "1",
    ]
    relaunched.launch()
    XCTAssertTrue(relaunched.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 30))
    openAlpha(relaunched)
    XCTAssertTrue(
      relaunched.buttons.containing(
        NSPredicate(format: "identifier BEGINSWITH %@", "composer-attachment-")
      ).firstMatch.waitForExistence(timeout: 15)
    )
    XCTAssertEqual(relaunched.textViews["composer-field"].value as? String, "Keep this")
  }

  func testDynamicTypeAndDarkAppearance() {
    let app = launch(appearance: "dark", extraArguments: [
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
    ])
    let image = app.buttons["transcript-image-media-image-1"]
    XCTAssertTrue(image.waitForExistence(timeout: 10))
    image.tap()
    XCTAssertTrue(app.descendants(matching: .any)["media-viewer"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["media-viewer-close"].isHittable)
  }
}
