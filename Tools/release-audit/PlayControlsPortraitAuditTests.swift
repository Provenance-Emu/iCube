// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest

/// Simulator only. Exercises real views through the read-only DEBUG fixture;
/// its injected actions cannot write states, load a game, change audio or quit.
final class PlayControlsPortraitAuditTests: XCTestCase {
  private var app: XCUIApplication!

  func testPortraitToolbarTargetsAndDirectPause() throws {
    try start()
    for id in ["pause", "save", "load", "saves", "options", "hide"] {
      let button = app.buttons["play-toolbar.\(id)"].firstMatch
      XCTAssertTrue(button.waitForExistence(timeout: 5), id)
      assertVisibleTarget(button)
    }
    let metric = app.staticTexts["play-preview.toolbar-height"].firstMatch
    XCTAssertTrue(metric.waitForExistence(timeout: 5))
    let height = try XCTUnwrap(Int(metric.label.split(separator: " ").last ?? ""))
    XCTAssertGreaterThanOrEqual(height, 44)
    XCTAssertLessThanOrEqual(height, 80)
    record("portrait-toolbar")
    app.buttons["play-toolbar.pause"].tap()
    XCTAssertTrue(app.staticTexts["play-preview.last-action"].waitForExistence(timeout: 3))
    waitForMarker("destination.pauseMenu")
    record("direct-pause-destination")
  }

  func testPortraitHistoryFooterAndSelectionAreClear() throws {
    try start(picker: "history")
    let save = app.buttons["quick-save-picker.save"].firstMatch
    let load = app.buttons["quick-save-picker.load"].firstMatch
    XCTAssertTrue(save.waitForExistence(timeout: 10))
    XCTAssertTrue(load.waitForExistence(timeout: 5))
    assertVisibleTarget(save)
    assertVisibleTarget(load)
    XCTAssertTrue(save.label.contains("Save"))
    XCTAssertTrue(load.label.contains("Load"))
    XCTAssertTrue(load.isEnabled)
    assertSinglePickerHeading()
    record("portrait-history")

    let kept = app.buttons["quick-save-picker.card.GALE01.quick-4F47B891-8628-45E3-98A3-A403A04BB4FB.s01"].firstMatch
    if !kept.isHittable { app.scrollViews.firstMatch.swipeUp() }
    XCTAssertTrue(kept.waitForExistence(timeout: 3))
    XCTAssertTrue(kept.isHittable)
    kept.tap()
    // Selecting a card must not invoke the injected load/save callbacks.
    XCTAssertEqual(app.staticTexts["play-preview.last-action"].label, "Ready")
    assertVisibleTarget(save)
    assertVisibleTarget(load)
    record("portrait-history-selected-without-load")
  }

  func testPortraitClassicEmptyAndIncompatibleSlots() throws {
    try start(picker: "slots")
    let save = app.buttons["quick-save-picker.save"].firstMatch
    let load = app.buttons["quick-save-picker.load"].firstMatch
    XCTAssertTrue(save.waitForExistence(timeout: 10))
    let empty = app.buttons["quick-save-picker.card.slot-1"].firstMatch
    XCTAssertTrue(empty.waitForExistence(timeout: 5))
    XCTAssertTrue(empty.isHittable)
    empty.tap()
    XCTAssertFalse(load.isEnabled)
    XCTAssertTrue(save.isEnabled)
    assertVisibleTarget(save)
    XCTAssertTrue(save.label.contains("1"))
    assertSinglePickerHeading()
    record("portrait-classic-empty")
    let incompatible = app.buttons["quick-save-picker.card.slot-4"].firstMatch
    if !incompatible.isHittable { app.scrollViews.firstMatch.swipeUp() }
    XCTAssertTrue(incompatible.isHittable)
    incompatible.tap()
    XCTAssertFalse(load.isEnabled)
    XCTAssertEqual(app.staticTexts["play-preview.last-action"].label, "Ready")
    assertVisibleTarget(save)
    record("portrait-classic-incompatible")
  }

  func testPortraitControllerAndShadersHaveTitles() throws {
    try start()
    let options = app.buttons["play-toolbar.options"].firstMatch
    XCTAssertTrue(options.waitForExistence(timeout: 5))
    options.tap()
    let controller = app.buttons["Controller"].firstMatch
    XCTAssertTrue(controller.waitForExistence(timeout: 5))
    controller.tap()
    XCTAssertTrue(app.buttons["On-Screen Controls"].firstMatch.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Wii Pointer"].firstMatch.exists)
    record("portrait-controller-menu")
    // Relaunching is safe here: this simulator fixture has no game or mutations.
    try start()
    app.buttons["play-toolbar.options"].tap()
    let shaders = app.buttons["Shaders"].firstMatch
    XCTAssertTrue(shaders.waitForExistence(timeout: 5))
    assertVisibleTarget(shaders)
    shaders.tap()
    waitForMarker("destination.shaders")
    record("portrait-shaders-direct-destination")
  }

  func testLandscapeHistoryActionsRemainOnscreen() throws {
    try start(picker: "history", landscape: true)
    let save = app.buttons["quick-save-picker.save"].firstMatch
    XCTAssertTrue(save.waitForExistence(timeout: 10))
    assertVisibleTarget(save)
    assertVisibleTarget(app.buttons["quick-save-picker.load"].firstMatch)
    assertSinglePickerHeading()
    assertInitialHistoryMetadataVisible()
    record("landscape-history")
  }

  func testLandscapeClassicInitialMetadataRemainsOnscreen() throws {
    try start(picker: "slots", landscape: true)
    let save = app.buttons["quick-save-picker.save"].firstMatch
    XCTAssertTrue(save.waitForExistence(timeout: 10))
    assertVisibleTarget(save)
    assertVisibleTarget(app.buttons["quick-save-picker.load"].firstMatch)
    let first = app.buttons["quick-save-picker.card.slot-1"].firstMatch
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    XCTAssertTrue(first.label.contains("Slot 1"), first.label)
    XCTAssertTrue(first.label.contains("Empty"), first.label)
    assertInitialCardFullyVisible(first)
    assertSinglePickerHeading()
    record("landscape-classic-initial-metadata")
  }

  private func assertInitialHistoryMetadataVisible() {
    let first = app.buttons["quick-save-picker.card.GALE01.quick-A2CC29A2-38BC-41B6-B37C-7624990EAE90.s01"].firstMatch
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    XCTAssertTrue(first.label.contains("Quick save"), first.label)
    XCTAssertTrue(first.label.contains("Occupied"), first.label)
    assertInitialCardFullyVisible(first)
  }

  private func assertInitialCardFullyVisible(_ card: XCUIElement) {
    // No swipe: the first full card (including the thumbnail and metadata) must fit initially.
    let scroll = app.scrollViews.firstMatch
    XCTAssertTrue(scroll.exists)
    XCTAssertTrue(card.isHittable)
    // ICubeRowButtonStyle draws a 1pt centered stroke: AX includes its 0.5pt
    // horizontal outset. Account only for that known stroke, keeping Y strict.
    let cardContent = card.frame.insetBy(dx: 0.5, dy: 0)
    XCTAssertTrue(scroll.frame.insetBy(dx: -0.001, dy: -0.001).contains(cardContent),
                  "Initial metadata is clipped: card \(card.frame), viewport \(scroll.frame)")
    XCTAssertLessThanOrEqual(card.frame.maxY, app.buttons["quick-save-picker.save"].firstMatch.frame.minY)
  }

  private func assertSinglePickerHeading() {
    let heading = app.staticTexts["quick-save-picker.header"].firstMatch
    XCTAssertTrue(heading.waitForExistence(timeout: 5))
    let titles = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Save States"))
      .allElementsBoundByIndex.filter { $0.isHittable }
    XCTAssertEqual(titles.count, 1, "The principal title must not be duplicated by a large navigation heading")
  }

  func testAccessibilityLandscapeHistoryActionsRemainOnscreen() throws {
    try start(picker: "history", landscape: true, largeText: true)
    let save = app.buttons["quick-save-picker.save"].firstMatch
    let load = app.buttons["quick-save-picker.load"].firstMatch
    XCTAssertTrue(save.waitForExistence(timeout: 10))
    assertVisibleTarget(save)
    assertVisibleTarget(load)
    XCTAssertLessThanOrEqual(save.frame.maxY, load.frame.minY + 0.001,
                             "Accessibility size must stack the actions without overlap")
    let first = app.buttons["quick-save-picker.card.GALE01.quick-A2CC29A2-38BC-41B6-B37C-7624990EAE90.s01"].firstMatch
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    XCTAssertTrue(first.label.contains("Quick save"), first.label)
    XCTAssertTrue(first.label.contains("Occupied"), first.label)
    let beforeScroll = first.frame.minY
    let scroll = app.scrollViews.firstMatch
    // Keep the same row in the lazy grid while measuring real content movement.
    // A full swipe can correctly virtualize it out of the accessibility tree.
    scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
      .press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
    XCTAssertTrue(first.exists)
    XCTAssertLessThan(first.frame.minY, beforeScroll, "Large-text metadata must remain in genuinely scrollable content")
    assertVisibleTarget(save)
    assertVisibleTarget(load)
    record("accessibility-landscape-history")
  }

  private func start(picker: String? = nil, landscape: Bool = false, largeText: Bool = false) throws {
    #if !targetEnvironment(simulator)
    throw XCTSkip("Read-only play controls fixtures run on simulators only")
    #endif
    continueAfterFailure = false
    executionTimeAllowance = 120
    XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
    app = XCUIApplication(bundleIdentifier: "com.joemattiello.iCube-debug")
    app.launchArguments = ["-ICubePlayControlsPreview", "-onboarding_seen_v1", "YES", "-SCREENSHOT_MODE", "0"]
    if let picker { app.launchArguments += ["-ICubePlayControlsPicker", picker] }
    if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    XCTAssertTrue(app.staticTexts["play-preview.last-action"].waitForExistence(timeout: 10))
    let orientation = NSPredicate { _, _ in
      landscape ? self.app.frame.width > self.app.frame.height : self.app.frame.height > self.app.frame.width
    }
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: orientation, object: nil)], timeout: 5),
                   .completed, "The app viewport must actually match the requested orientation: \(app.frame)")
  }

  private func waitForMarker(_ expected: String) {
    let marker = app.staticTexts["play-preview.last-action"].firstMatch
    let matches = NSPredicate(format: "label == %@", expected)
    XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: marker)], timeout: 5) == .completed,
                  "Destination handoff did not arrive: expected \(expected), got \(marker.label)")
  }

  private func assertVisibleTarget(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(element.exists, file: file, line: line)
    XCTAssertTrue(element.isHittable, "\(element.identifier): \(element.frame)", file: file, line: line)
    // AX geometry can represent 44pt as 43.99999999999997; tolerate <1/1000pt rounding.
    XCTAssertGreaterThanOrEqual(element.frame.height + 0.001, 44, file: file, line: line)
    XCTAssertGreaterThanOrEqual(element.frame.width + 0.001, 44, file: file, line: line)
    XCTAssertTrue(app.frame.contains(element.frame), "Offscreen: \(element.frame)", file: file, line: line)
  }

  private func record(_ name: String) {
    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = name + "-accessibility"
    tree.lifetime = .keepAlways
    add(tree)
  }
}
