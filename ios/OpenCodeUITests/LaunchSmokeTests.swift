import XCTest

/// UI automation for the launch and connection shell. Scenarios are pinned through launch
/// arguments, so every test is offline and deterministic; no test taps a control that would redeem
/// a pairing code or contact a host.
final class LaunchSmokeTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  private func launch(
    scenario: String? = nil,
    extraArguments: [String] = [],
    environment: [String: String] = [:]
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments =
      ["-uiTesting", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extraArguments
    var merged = environment
    if let scenario { merged["OPENCODE_UI_TEST_SCENARIO"] = scenario }
    app.launchEnvironment = merged
    app.launch()
    return app
  }

  func testFirstLaunchShowsDisconnectedState() {
    let app = launch(scenario: "disconnected")

    XCTAssertTrue(
      app.descendants(matching: .any)["root-phase-disconnected"].waitForExistence(timeout: 10)
    )
    XCTAssertTrue(app.staticTexts["OpenCode"].exists)
    XCTAssertTrue(app.buttons["Enter a Server Manually"].exists)
    XCTAssertTrue(app.buttons["Scan QR Code"].exists)
    XCTAssertTrue(app.buttons["Paste Pairing Link"].exists)
  }

  func testManualEntryValidatesAnAddress() {
    let app = launch(scenario: "disconnected")
    app.buttons["Enter a Server Manually"].tap()

    let address = app.textFields["server-form-address"]
    XCTAssertTrue(address.waitForExistence(timeout: 5))
    address.tap()
    address.typeText("ftp://laptop.local")
    app.buttons["Connect"].tap()

    XCTAssertTrue(app.staticTexts["The address must start with http:// or https://."].exists)
  }

  func testEmptyClipboardIsReported() {
    let app = launch(
      scenario: "disconnected",
      environment: ["OPENCODE_UI_TEST_CLIPBOARD": ""]
    )
    app.buttons["Paste Pairing Link"].tap()

    XCTAssertTrue(app.staticTexts["Your clipboard is empty."].waitForExistence(timeout: 5))
  }

  func testConnectedDestinationShowsProjects() {
    let app = launch(scenario: "connected")

    XCTAssertTrue(
      app.descendants(matching: .any)["root-phase-connected"].waitForExistence(timeout: 10)
    )
    XCTAssertTrue(app.staticTexts["Studio"].exists)
    XCTAssertTrue(app.staticTexts["Projects"].exists)
    XCTAssertTrue(app.staticTexts["OpenCode"].exists)
  }

  func testReconnectingShowsCachedProjects() {
    let app = launch(scenario: "reconnecting")

    XCTAssertTrue(
      app.descendants(matching: .any)["root-phase-reconnecting"].waitForExistence(timeout: 10)
    )
    XCTAssertTrue(app.staticTexts["Reconnecting…"].exists)
    XCTAssertTrue(app.buttons["Try Again"].exists)
  }

  func testRejectedCredentialsOfferEditing() {
    let app = launch(scenario: "failed-auth")

    XCTAssertTrue(
      app.descendants(matching: .any)["root-phase-failed"].waitForExistence(timeout: 10)
    )
    XCTAssertTrue(app.staticTexts["The server rejected these credentials."].exists)
    XCTAssertTrue(app.buttons["Edit Server"].exists)
  }

  func testIncompatibleAPIHasItsOwnCopy() {
    let app = launch(scenario: "failed-incompatible")

    let message = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "This address answered with a web page")
    ).firstMatch
    XCTAssertTrue(message.waitForExistence(timeout: 10))
  }

  func testOfflineIsDistinctFromBadCredentials() {
    let app = launch(scenario: "failed-offline")

    XCTAssertTrue(app.staticTexts["There’s no network connection."].waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["The server rejected these credentials."].exists)
  }

  func testUnreachableServerOffersRetry() {
    let app = launch(scenario: "failed-unreachable")

    XCTAssertTrue(app.staticTexts["Couldn’t reach the OpenCode server."].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["Try Again"].exists)
    XCTAssertTrue(app.buttons["Edit Server"].exists)
  }

  func testStorageFailureKeepsCredentials() {
    let app = launch(scenario: "storage-unavailable")

    XCTAssertTrue(
      app.descendants(matching: .any)["root-phase-storage"].waitForExistence(timeout: 10)
    )
    XCTAssertTrue(app.buttons["Try Again"].exists)
    XCTAssertTrue(app.buttons["Enter a Server Manually"].exists)
  }

  func testManualEntryFromStorageUnavailableShowsConnectionAndWarning() {
    let app = launch(scenario: "storage-unavailable")
    app.buttons["Enter a Server Manually"].tap()

    let address = app.textFields["server-form-address"]
    XCTAssertTrue(address.waitForExistence(timeout: 5))
    address.tap()
    address.typeText("laptop.local:4096")
    app.buttons["Connect"].tap()

    XCTAssertTrue(
      app.descendants(matching: .any)["root-phase-loading"].waitForExistence(timeout: 5)
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["saved-data-warning"].waitForExistence(timeout: 5)
    )
  }

  func testManualEntryFromCorruptSavedShowsConnectionAndWarning() {
    let app = launch(scenario: "corrupt-saved")
    app.buttons["Enter a Server Manually"].tap()

    let address = app.textFields["server-form-address"]
    XCTAssertTrue(address.waitForExistence(timeout: 5))
    address.tap()
    address.typeText("laptop.local:4096")
    app.buttons["Connect"].tap()

    XCTAssertTrue(
      app.descendants(matching: .any)["root-phase-loading"].waitForExistence(timeout: 5)
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["saved-data-warning"].waitForExistence(timeout: 5)
    )
    XCTAssertTrue(app.buttons["Replace Saved Servers"].exists)
    app.buttons["Replace Saved Servers"].tap()
    XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
    XCTAssertTrue(app.alerts.staticTexts["Replace Saved Servers?"].exists)
    app.alerts.buttons["Cancel"].tap()
  }

  func testCorruptStorageOffersAnExplicitReset() {
    let app = launch(scenario: "corrupt-saved")

    XCTAssertTrue(
      app.descendants(matching: .any)["root-phase-corrupt"].waitForExistence(timeout: 10)
    )
    XCTAssertTrue(app.buttons["Forget Saved Servers"].exists)
  }

  func testSetupScanShowsConfirmationWithoutRedeeming() {
    let payload = "opencode-ios://pair?code=Pair-123_xyz&url=https%3A%2F%2Fstudio.invalid"
    let app = launch(
      scenario: "disconnected",
      extraArguments: ["-uiTestPairingPayload", payload],
      environment: ["OPENCODE_UI_TEST_FIXTURE": "disconnected"]
    )
    XCTAssertTrue(app.buttons["connection-scan-qr"].waitForExistence(timeout: 10))
    app.buttons["connection-scan-qr"].tap()

    let alert = app.alerts.firstMatch
    XCTAssertTrue(alert.waitForExistence(timeout: 15))
    XCTAssertTrue(alert.staticTexts["Pair with studio.invalid?"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["root-phase-pairing"].exists)
    alert.buttons["Cancel"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["root-phase-disconnected"].waitForExistence(timeout: 10)
    )
  }

  func testDeepLinkShowsPairingConfirmationWithoutRedeeming() {
    let app = launch(
      scenario: "disconnected",
      environment: {
        var environment: [String: String] = [:]
        environment["OPENCODE_UI_TEST_OPEN_URL"] =
          "opencode-ios://pair?code=Pair-123_xyz&url=https%3A%2F%2Fstudio.invalid"
        return environment
      }()
    )

    XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
    XCTAssertTrue(app.alerts.firstMatch.staticTexts["Pair with studio.invalid?"].exists)
    XCTAssertTrue(app.alerts.buttons["Pair"].exists)
    app.alerts.buttons["Cancel"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["root-phase-disconnected"].waitForExistence(timeout: 5)
    )
  }

  func testLoadingStateIsReachable() {
    let app = launch(scenario: "loading")

    XCTAssertTrue(
      app.descendants(matching: .any)["root-phase-loading"].waitForExistence(timeout: 10)
    )
  }
}
