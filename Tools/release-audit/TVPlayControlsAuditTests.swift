// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest

/// Read-only DEBUG fixture; injected operations cannot mutate saves or a core.
final class TVPlayControlsAuditTests: XCTestCase {
  private var app: XCUIApplication!

  func testHistoryFocusMovesAndBackDismisses() throws {
    try start(mode: "history")
    let initial = try focusedButton()
    record("tv-history-initial-focus")
    var moved = false
    for direction in [XCUIRemote.Button.down, .right, .up, .left] {
      XCUIRemote.shared.press(direction)
      if try focusedButton().identifier != initial.identifier { moved = true; break }
    }
    XCTAssertTrue(moved, "Remote navigation must move visible button focus")
    record("tv-history-moved-focus")
    XCUIRemote.shared.press(.menu)
    XCTAssertTrue(app.buttons["Open save preview"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["play-preview.last-action"].label, "picker.done")
    record("tv-history-back")
  }

  func testClassicEmptyAndIncompatibleLoadDisabled() throws {
    try start(mode: "slots")
    let load = app.buttons["quick-save-picker.load"]
    for slot in [1, 4] {
      let card = app.buttons["quick-save-picker.card.slot-\(slot)"]
      try focus(card)
      XCUIRemote.shared.press(.select)
      XCTAssertFalse(load.isEnabled, "Empty or incompatible states cannot load")
      XCTAssertEqual(app.staticTexts["play-preview.last-action"].label, "Ready")
      record("tv-classic-slot-\(slot)")
    }
    XCUIRemote.shared.press(.menu)
    XCTAssertTrue(app.buttons["Open save preview"].waitForExistence(timeout: 5))
  }

  private func start(mode: String) throws {
    continueAfterFailure = false
    executionTimeAllowance = 120
    app = XCUIApplication(bundleIdentifier: "com.joemattiello.iCube-debug")
    app.launchArguments = ["-ICubePlayControlsPreview", "-ICubePlayControlsPicker", mode,
                           "-onboarding_seen_v1", "YES", "-SCREENSHOT_MODE", "0"]
    app.launch()
    XCTAssertTrue(app.buttons["quick-save-picker.save"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.buttons["quick-save-picker.load"].exists)
  }

  private func focusedButton() throws -> XCUIElement {
    let ready = NSPredicate { _, _ in self.app.buttons.allElementsBoundByIndex.contains { $0.hasFocus } }
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 5), .completed)
    return try XCTUnwrap(app.buttons.allElementsBoundByIndex.first { $0.hasFocus })
  }

  private func focus(_ target: XCUIElement) throws {
    XCTAssertTrue(target.waitForExistence(timeout: 5))
    for _ in 0..<16 {
      if target.hasFocus { return }
      let current = try focusedButton()
      let dx = target.frame.midX - current.frame.midX
      let dy = target.frame.midY - current.frame.midY
      let direction: XCUIRemote.Button = abs(dy) > 50 ? (dy > 0 ? .down : .up) : (dx > 0 ? .right : .left)
      XCUIRemote.shared.press(direction)
    }
    record("tv-focus-failed")
    XCTFail("Could not focus \(target.identifier)")
  }

  private func record(_ name: String) {
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = name + "-accessibility"
    tree.lifetime = .keepAlways
    add(tree)
  }
}
