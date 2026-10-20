// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest

/// Physical DEV app only. Launches the existing Luigi's Mansion ROM, then leaves
/// it paused. Never selects Quit, Save & Quit, Reset, or a library context action.
final class PhysicalRealGamePauseExitAuditTests: XCTestCase {
  private var app: XCUIApplication!

  func testRealGameExitActionsCancelAndReopen() throws {
    continueAfterFailure = false
    executionTimeAllowance = 150
    app = XCUIApplication(bundleIdentifier: "com.joemattiello.iCube-debug")
    app.launchArguments = ["-onboarding_seen_v1", "YES", "-SCREENSHOT_MODE", "0"]
    if app.state == .notRunning { app.launch() } else { app.activate() }
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
    record("01-dev-initial-state")

    // Accept a prior paused DEV session without resuming or starting another game.
    let exit = app.buttons["pause.tile.exit"].firstMatch
    if !exit.exists && !app.buttons["Pause"].exists && !app.buttons["Resume"].exists {
      let title = NSPredicate(format: "label CONTAINS[cd] %@", "Luigi")
      let card = app.buttons.matching(title).firstMatch
      if card.waitForExistence(timeout: 20), card.isHittable {
        record("02-luigi-library-card")
        card.tap()
      } else {
        // Some SwiftUI library layouts expose the card title as static text.
        let text = app.staticTexts.matching(title).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5), "Existing Luigi's Mansion library card is missing")
        XCTAssertTrue(text.isHittable, "Existing Luigi library card is not onscreen")
        record("02-luigi-library-title")
        text.tap()
      }
    }

    if !exit.exists {
      let pause = app.buttons["Pause"].firstMatch
      let resume = app.buttons["Resume"].firstMatch
      let playingOrPaused = NSPredicate { _, _ in pause.exists || resume.exists || exit.exists }
      let ready = XCTNSPredicateExpectation(predicate: playingOrPaused, object: nil)
      let result = XCTWaiter.wait(for: [ready], timeout: 45)
      record("03-game-start-result")
      XCTAssertEqual(result, .completed, "Game did not expose Pause/Resume within 45 seconds")
      if pause.exists && pause.isHittable { pause.tap() }
      if !exit.exists {
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "Paused emulation must expose toolbar More")
        XCTAssertTrue(more.isHittable)
        more.tap()
        record("04-toolbar-more")
        let pauseMenu = app.buttons["Pause Menu"].firstMatch
        XCTAssertTrue(pauseMenu.waitForExistence(timeout: 5))
        XCTAssertTrue(pauseMenu.isHittable)
        pauseMenu.tap()
      }
    }

    XCTAssertTrue(exit.waitForExistence(timeout: 10), "Pause menu Exit tile is missing")
    record("05-real-game-pause-menu")
    for iteration in 1...2 {
      XCTAssertTrue(exit.isHittable, "Pause menu Exit tile must accept touch")
      exit.tap()
      XCTAssertTrue(app.staticTexts["Exit Game"].firstMatch.waitForExistence(timeout: 5))
      record("06-exit-prompt-\(iteration)")
      for name in ["Cancel", "Quit", "Save & Quit"] {
        let action = app.buttons[name].firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 3), "Missing exit action: \(name)")
        XCTAssertTrue(action.isHittable, "Exit action must be hittable: \(name); \(action.frame)")
        XCTAssertGreaterThan(action.frame.width, 30)
        XCTAssertGreaterThan(action.frame.height, 20)
        XCTAssertTrue(app.frame.contains(action.frame), "Exit action is offscreen: \(name)")
      }
      app.buttons["Cancel"].firstMatch.tap()
      XCTAssertTrue(app.staticTexts["Exit Game"].firstMatch.waitForNonExistence(timeout: 5))
      XCTAssertTrue(exit.waitForExistence(timeout: 5))
      record("07-exit-cancelled-\(iteration)")
    }
    // The pause menu remains open, holding the emulator paused. No teardown
    // terminates the app or changes the user's game/session state.
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
