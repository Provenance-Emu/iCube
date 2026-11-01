// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest

/// Standalone iOS UI test against the real library context-menu route. Uses the existing DEBUG
/// screenshot catalogue only for artwork; these synthetic entries are never treated as local ROMs.
final class NetworkPlayContextAuditTests: XCTestCase {
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
}
