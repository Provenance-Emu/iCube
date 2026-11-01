// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import UIKit
import XCTest

/// Standalone iOS UI test against the real library context-menu route. Uses the existing DEBUG
/// screenshot catalogue only for artwork; these synthetic entries are never treated as local ROMs.
final class NetworkPlayContextAuditTests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
    #if !targetEnvironment(simulator)
    throw XCTSkip("Fixture audits run only on explicitly selected simulators.")
    #endif
  }

  func testIPadLandscapeLayout() throws {
    try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires an iPad simulator")
    let app = XCUIApplication(bundleIdentifier: "com.joemattiello.iCube-debug")
    app.launchArguments = ["-onboarding_seen_v1", "YES", "-SCREENSHOT_MODE", "1", "-ICubeAppearance", "dark", "-ICubeNetworkPlayPreview"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Network Play is not available in this iCube build."].waitForExistence(timeout: 10))
    XCUIDevice.shared.orientation = .landscapeLeft
    let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 10), .completed)
    XCTAssertTrue(app.staticTexts["Nearby Rooms"].isHittable)
    XCTAssertTrue(app.textFields["networkPlay.search"].isHittable)
    XCTAssertTrue(app.staticTexts["No games to recommend yet"].isHittable)
    capture(app, name: "network-play-ipad-landscape")
    app.buttons["networkPlay.settings"].tap()
    XCTAssertTrue(app.switches["networkPlay.unverifiedToggle"].isHittable)
    XCTAssertEqual(app.switches["networkPlay.unverifiedToggle"].value as? String, "0")
    capture(app, name: "network-play-ipad-landscape-settings")
  }

  func testGameContextOpensThatGamesEvidenceDetails() throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "com.joemattiello.iCube-debug")
    app.launchArguments = ["-onboarding_seen_v1", "YES", "-SCREENSHOT_MODE", "1", "-ICubeAppearance", "dark"]
    app.launch()
    let game = app.staticTexts["Cube Quest"].firstMatch
    XCTAssertTrue(game.waitForExistence(timeout: 10))
    game.press(forDuration: 1.2)
    let action = app.buttons["Network Play"].firstMatch
    XCTAssertTrue(action.waitForExistence(timeout: 5))
    action.tap()
    XCTAssertTrue(app.staticTexts["Host unavailable"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Cube Quest"].exists)
    XCTAssertTrue(app.staticTexts["Documented multiplayer"].exists)
    XCTAssertTrue(app.staticTexts["Test evidence"].exists)
    XCTAssertFalse(app.buttons["Host"].exists)
    let capture = XCTAttachment(screenshot: app.screenshot())
    capture.name = "network-play-game-details"
    capture.lifetime = .keepAlways
    add(capture)
    app.buttons["networkPlay.back"].tap()
    XCTAssertTrue(app.staticTexts["No games to recommend yet"].waitForExistence(timeout: 5))
  }

  private func capture(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
