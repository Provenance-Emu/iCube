// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import UIKit

/// External rendered regression. Uses a synthetic pause preview; never quits or saves.
final class IOSPauseExitAuditTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    executionTimeAllowance = 120
    app = XCUIApplication(bundleIdentifier: "com.joemattiello.iCube-debug")
    app.launchArguments = ["-ICubePausePreview", "-ICubePausePane", "exit",
      "-onboarding_seen_v1", "YES", "-ICubeAppearance", "dark", "-AppleLanguages", "(en)"]
  }

  override func tearDown() {
    app?.terminate()
    XCUIDevice.shared.orientation = .portrait
    super.tearDown()
  }

  func testPortraitExitActionsCancelAndReopen() {
    verify(orientation: .portrait, name: "portrait")
  }

  func testLandscapeExitActionsCancelAndReopen() {
    verify(orientation: .landscapeLeft, name: "landscape")
  }

  private func verify(orientation: UIDeviceOrientation, name: String) {
    XCUIDevice.shared.orientation = orientation
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    XCTAssertTrue(app.staticTexts["Exit Game"].firstMatch.waitForExistence(timeout: 20))
    record(name + "-exit-initial")
    assertActionsOnscreen()
    app.buttons["Cancel"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Exit Game"].firstMatch.waitForNonExistence(timeout: 5),
      "Cancel must dismiss the exit prompt")
    let exit = app.buttons["pause.tile.exit"].firstMatch
    XCTAssertTrue(exit.waitForExistence(timeout: 5), "Pause Exit tile must be restored")
    XCTAssertTrue(exit.isHittable, "Pause Exit tile must accept touch after Cancel")
    exit.tap()
    XCTAssertTrue(app.staticTexts["Exit Game"].firstMatch.waitForExistence(timeout: 5))
    assertActionsOnscreen()
    record(name + "-exit-reopened")
    app.buttons["Cancel"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Exit Game"].firstMatch.waitForNonExistence(timeout: 5))
  }

  private func assertActionsOnscreen() {
    for name in ["Cancel", "Quit", "Save & Quit"] {
      let action = app.buttons[name].firstMatch
      XCTAssertTrue(action.waitForExistence(timeout: 5), "Missing exit action: \(name)")
      XCTAssertTrue(action.isHittable, "Exit action must be hittable: \(name); frame=\(action.frame)")
      XCTAssertGreaterThan(action.frame.width, 30, "Exit action has collapsed width: \(name)")
      XCTAssertGreaterThan(action.frame.height, 20, "Exit action has collapsed height: \(name)")
      XCTAssertTrue(app.frame.contains(action.frame), "Exit action extends offscreen: \(name); \(action.frame), viewport \(app.frame)")
    }
  }

  private func record(_ name: String) {
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = name + "-accessibility"
    tree.lifetime = .keepAlways
    add(tree)
  }
}
