// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest

/// Opt-in physical DEV checks against an ALREADY RUNNING disposable real-game
/// session. The operator preflights the DEV container; this test never launches
/// a game, touches the production bundle, or terminates either app.
final class PhysicalPlayControlsSmokeTests: XCTestCase {
  private var app: XCUIApplication!
  private var originalVolumeForCleanup: Int?
  private let cardPrefix = "quick-save-picker.card."

  override func setUpWithError() throws {
    continueAfterFailure = false
    executionTimeAllowance = 120
    try XCTSkipUnless(ProcessInfo.processInfo.environment["ICUBE_PLAY_CONTROLS_PREFLIGHT"] == "enabled",
                      "Requires operator DEV real-game/session preflight")
    try XCTSkipUnless(ProcessInfo.processInfo.environment["ICUBE_PLAY_CONTROLS_WIDE_PREFLIGHT"] == "enabled",
                      "Operator must select full-screen landscape iPad, width >= 1000pt, standard Dynamic Type; compact audit is separate")
    app = XCUIApplication(bundleIdentifier: "com.joemattiello.iCube-debug")
    try XCTSkipIf(app.state == .notRunning, "Prepare an existing disposable DEV game; no launch is permitted here")
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    record("01-existing-dev-session")
    addTeardownBlock { [self] in
      // Complete all cleanup attempts before assertions: XCTest may interrupt
      // control flow at a failure when continueAfterFailure is false.
      let done = app.buttons["quick-save-picker.done"].firstMatch
      if done.exists && done.isHittable { done.tap() }
      let audioRestored = restoreOriginalVolumeIfNeeded()
      let audioDismissed = dismissAudioPopoverIfPresent()
      for _ in 0..<2 {
        if app.buttons["pause.tile.exit"].exists { break }
        revealToolbarIfHidden()
        let pause = app.buttons["play-toolbar.pause"].firstMatch
        if pause.exists && pause.isHittable { pause.tap() }
      }
      let paused = app.buttons["pause.tile.exit"].firstMatch.waitForExistence(timeout: 5)
      record("99-dev-final-state")
      XCTAssertTrue(audioRestored, "Cleanup could not verify original DEV volume; inspect final attachments")
      XCTAssertTrue(audioDismissed, "Cleanup could not dismiss Audio before pausing; inspect final attachments")
      XCTAssertTrue(paused, "Cleanup could not confirm paused DEV; inspect final attachments")
    }
  }

  func testToolbarMuteRestoresVolumeAndHistoryUI() throws {
    try exposeToolbarFromExistingSession()
    for (id, label) in [("pause", "Pause"), ("save", "Quick Save"), ("load", "Quick Load"),
                        ("saves", "Save States"), ("audio", "Audio"), ("controller", "Controller"),
                        ("shaders", "Shaders")] {
      let control = app.buttons["play-toolbar.\(id)"].firstMatch
      assertTarget(control)
      XCTAssertEqual(control.label, label)
    }
    app.buttons["play-toolbar.audio"].firstMatch.tap()
    let volume = app.sliders["Volume"].firstMatch
    XCTAssertTrue(volume.waitForExistence(timeout: 5))
    let original = try volumePercent(volume)
    try XCTSkipUnless(original > 0, "Start with audible nonzero configured volume to verify mute restoration")
    // Register restoration before the first mutation, including assertion interruption.
    originalVolumeForCleanup = original
    let mute = app.buttons["Mute"].firstMatch
    assertTarget(mute)
    record("02-audio-before-mute")
    mute.tap()
    XCTAssertTrue(waitUntil { (try? self.volumePercent(volume)) == 0 })
    record("03-mute-slider-zero")
    mute.tap()
    XCTAssertTrue(waitUntil { (try? self.volumePercent(volume)) == original })
    record("04-unmute-original-volume")
    try dismissAudioUsingPauseTarget()
    try exposeToolbarFromExistingSession()
    app.buttons["play-toolbar.saves"].firstMatch.tap()
    try assertHistoryBrowser()
    assertTarget(app.buttons["quick-save-picker.done"].firstMatch)
    record("05-history-browser-read-only")
    app.buttons["quick-save-picker.done"].firstMatch.tap()
    try leavePaused()
  }

  func testOneNewHistorySaveAndExplicitLoadSameCard() throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(environment["ICUBE_HISTORY_SAVE_PREFLIGHT"] == "enabled",
      "Operator must verify DEV Confirm on Stop=true, history mode, fewer than ten unkept history saves, and authorize exactly one new save/load")
    let inventoryData = try XCTUnwrap(environment["ICUBE_HISTORY_EXISTING_BASENAMES"]?.data(using: .utf8),
      "Supply complete DEV history basename inventory, including kept saves, as a JSON array")
    let existing = Set(try JSONDecoder().decode([String].self, from: inventoryData))
    try exposeToolbarFromExistingSession()
    app.buttons["play-toolbar.saves"].firstMatch.tap()
    try assertHistoryBrowser()
    let save = app.buttons["quick-save-picker.save"].firstMatch
    assertTarget(save)
    XCTAssertEqual(save.label, "Save new state", "Abort on classic slots; never fall back to a classic save")
    record("06-history-before-single-save")
    save.tap() // The only save mutation in this entire harness. No retry.
    XCTAssertTrue(waitUntil(timeout: 30) { self.newHistoryCards(excluding: existing).count == 1 },
                  "Must identify exactly one newly created immutable history filename")
    let newCards = newHistoryCards(excluding: existing)
    XCTAssertEqual(newCards.count, 1)
    let identifier = try XCTUnwrap(newCards.first)
    let created = app.buttons[identifier].firstMatch
    assertTarget(created)
    record("07-new-immutable-history-card")
    created.tap() // Selection alone does not load.
    XCTAssertTrue(created.isSelected, "New card must be selected before explicit Load")
    let load = app.buttons["quick-save-picker.load"].firstMatch
    assertTarget(load)
    XCTAssertEqual(load.label, "Load selected")
    record("08-same-new-card-selected")
    load.tap() // Never Quick Load or an existing history/classic/kept state.
    XCTAssertTrue(app.buttons["quick-save-picker.done"].firstMatch.waitForNonExistence(timeout: 20),
                  "Successful explicit load should dismiss the picker")
    record("09-explicit-load-dismissed")
    try leavePaused()
  }

  private func assertHistoryBrowser() throws {
    let history = app.buttons["quick-save-picker.mode.history"].firstMatch
    XCTAssertTrue(history.waitForExistence(timeout: 8))
    XCTAssertTrue(history.isSelected, "Preflight must already select history; do not switch modes in this audit")
    XCTAssertEqual(app.buttons["quick-save-picker.save"].firstMatch.label, "Save new state")
    XCTAssertFalse(app.staticTexts["Modded games use classic slots. Automatic resume and quick-save history are unavailable."].exists)
  }

  private func newHistoryCards(excluding existing: Set<String>) -> [String] {
    app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", cardPrefix)).allElementsBoundByIndex
      .map(\.identifier).filter {
        let basename = String($0.dropFirst(cardPrefix.count))
        return basename.contains(".quick-") && basename.hasSuffix(".s01") && !existing.contains(basename)
      }
  }

  private func exposeToolbarFromExistingSession() throws {
    let exit = app.buttons["pause.tile.exit"].firstMatch
    if exit.exists {
      let resume = app.buttons["pause.tile.resume"].firstMatch
      assertTarget(resume)
      resume.tap() // Disposable DEV session only; no other game is started.
      XCTAssertTrue(exit.waitForNonExistence(timeout: 5))
    }
    try XCTSkipUnless(app.frame.width >= 1000 && app.frame.width > app.frame.height,
                      "This audit requires full-screen landscape iPad width >= 1000pt")
    revealToolbarIfHidden()
    let audio = app.buttons["play-toolbar.audio"].firstMatch
    try XCTSkipUnless(audio.waitForExistence(timeout: 5),
                      "Wide toolbar unavailable (compact/accessibility layout); use its separate audit")
    XCTAssertTrue(app.buttons["play-toolbar.pause"].firstMatch.waitForExistence(timeout: 5),
                  "Existing real-game toolbar required; no library launch fallback")
  }

  /// Idempotent best effort. Adjust the native slider to the exact captured
  /// original value on ANY mismatch (including a wrong positive unmute value).
  /// This deliberately avoids toggling Mute, whose remembered level may be wrong.
  private func restoreOriginalVolumeIfNeeded() -> Bool {
    guard let original = originalVolumeForCleanup else { return true }
    let volume = app.sliders["Volume"].firstMatch
    if !volume.exists {
      let resume = app.buttons["pause.tile.resume"].firstMatch
      if resume.exists && resume.isHittable { resume.tap() }
      revealToolbarIfHidden()
      let audio = app.buttons["play-toolbar.audio"].firstMatch
      if audio.waitForExistence(timeout: 5) && audio.isHittable { audio.tap() }
    }
    guard volume.waitForExistence(timeout: 5), volume.isHittable else { return false }
    for _ in 0..<3 {
      if readVolumePercent(volume) == original { return true }
      volume.adjust(toNormalizedSliderPosition: CGFloat(original) / 100)
      if waitUntil { self.readVolumePercent(volume) == original } { return true }
    }
    return readVolumePercent(volume) == original
  }

  /// Native iPad popovers can mark their background Pause button unhittable.
  /// Its known on-screen center is the only permitted outside-dismiss coordinate;
  /// never use a game-picture point or a save/load target for dismissal.
  private func dismissAudioPopoverIfPresent() -> Bool {
    let volume = app.sliders["Volume"].firstMatch
    guard volume.exists else { return true }
    let pause = app.buttons["play-toolbar.pause"].firstMatch
    guard app.alerts.count == 0, pause.exists, pause.isEnabled,
          pause.label == "Pause", app.frame.contains(pause.frame),
          pause.frame.width > 0, pause.frame.height > 0 else { return false }
    let center = CGPoint(x: pause.frame.midX, y: pause.frame.midY)
    let popover = app.popovers.firstMatch
    // If the native popover exposes its bounds, prove the point is outside it.
    guard !popover.exists || !popover.frame.contains(center) else { return false }
    if pause.isHittable { pause.tap() }
    else { pause.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
    return volume.waitForNonExistence(timeout: 5)
  }

  private func dismissAudioUsingPauseTarget() throws {
    XCTAssertTrue(dismissAudioPopoverIfPresent(), "Audio must dismiss before normal Pause interaction")
    try leavePaused()
  }

  private func leavePaused() throws {
    if !app.buttons["pause.tile.exit"].exists {
      revealToolbarIfHidden()
      let pause = app.buttons["play-toolbar.pause"].firstMatch
      assertTarget(pause)
      pause.tap()
    }
    XCTAssertTrue(app.buttons["pause.tile.exit"].firstMatch.waitForExistence(timeout: 8),
                  "Final DEV pause menu must remain visible")
    record("10-dev-left-paused")
  }

  private func revealToolbarIfHidden() {
    guard !app.buttons["play-toolbar.pause"].exists, app.alerts.count == 0 else { return }
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
      .withOffset(CGVector(dx: 0, dy: 20)).tap()
  }

  private func readVolumePercent(_ slider: XCUIElement) -> Int? {
    guard let value = slider.value as? String else { return nil }
    return Int(value.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
  }

  private func volumePercent(_ slider: XCUIElement) throws -> Int {
    try XCTUnwrap(readVolumePercent(slider), "Unexpected Volume accessibility value: \(String(describing: slider.value))")
  }

  private func assertTarget(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
    XCTAssertTrue(element.isEnabled && element.isHittable, file: file, line: line)
    XCTAssertGreaterThanOrEqual(element.frame.width + 0.001, 44, file: file, line: line)
    XCTAssertGreaterThanOrEqual(element.frame.height + 0.001, 44, file: file, line: line)
    XCTAssertTrue(app.frame.contains(element.frame), file: file, line: line)
  }

  private func waitUntil(timeout: TimeInterval = 5, _ predicate: @escaping () -> Bool) -> Bool {
    XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)], timeout: timeout) == .completed
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
