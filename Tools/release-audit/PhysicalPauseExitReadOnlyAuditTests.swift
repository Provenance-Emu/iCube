// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest

/// Inspect an already-running TestFlight game without launching or terminating it.
/// Never selects a game, Quit, or Save & Quit. Cancel is the only permitted tap.
final class PhysicalPauseExitReadOnlyAuditTests: XCTestCase {
  func testExistingExitPromptActionsAndSafeCancel() throws {
    continueAfterFailure = false
    executionTimeAllowance = 90
    let app = XCUIApplication(bundleIdentifier: "com.joemattiello.iCube")
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
    record(app, name: "physical-ipad-existing-state")
    guard app.staticTexts["Exit Game"].firstMatch.waitForExistence(timeout: 5) else {
      throw XCTSkip("Exit prompt is not already open; captured current state without starting a game")
    }
    for name in ["Cancel", "Quit", "Save & Quit"] {
      let button = app.buttons[name].firstMatch
      XCTAssertTrue(button.waitForExistence(timeout: 3), "Missing exit action: \(name)")
      XCTAssertTrue(button.isHittable, "Exit action is not hittable: \(name); \(button.frame)")
      XCTAssertGreaterThan(button.frame.height, 20, "Exit action has collapsed height: \(name)")
      XCTAssertTrue(app.frame.contains(button.frame), "Exit action extends offscreen: \(name)")
    }
    app.buttons["Cancel"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Exit Game"].firstMatch.waitForNonExistence(timeout: 5))
    record(app, name: "physical-ipad-exit-cancelled")
  }

  private func record(_ app: XCUIApplication, name: String) {
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
