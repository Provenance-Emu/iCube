// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import UIKit

/// External, rendered tvOS acceptance suite. Requires the isolated fixture recipe
/// in tvos-library-editing.md. Never selects a library tile with a short press.
final class TVLibraryEditingAuditTests: XCTestCase {
  private let original = "ICube Library Edit Audit NEVER LAUNCH.dol"
  private let saved = "Audit Custom Title"
  private var app: XCUIApplication!
  private var caseStarted = Date()
  private enum AuditFailure: Error { case focus, editor, keyboard, artwork, deadline }

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    executionTimeAllowance = 180
    caseStarted = Date()
    app = XCUIApplication(bundleIdentifier: "com.joemattiello.iCube-debug")
    // Demo entries intentionally have no editor. Override any prior demo default.
    app.launchArguments = ["-SCREENSHOT_MODE", "0", "-onboarding_seen_v1", "YES",
      "-ICubeAppearance", "dark", "-library_platform_filter", "all", "-AppleLanguages", "(en)"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    // A failed previous run can leave this disposable fixture's saved edits.
    // Reset only that known title through the real editor, never delete data.
    if app.staticTexts[saved].waitForExistence(timeout: 2) {
      try openEditor(tileTitle: saved)
      try replace(app.textFields.element(boundBy: 0), with: "")
      try replace(app.textFields["Tags separated by commas"], with: "")
      try activate(app.buttons["Use Original Cover"])
      try activate(app.buttons["Save"])
      XCTAssertTrue(app.staticTexts[original].waitForExistence(timeout: 10))
    }
  }

  override func tearDown() {
    app?.terminate()
    super.tearDown()
  }

  func testTitleTagsSaveCancelReopenAndRelaunch() throws {
    try openEditor(tileTitle: original)
    try replace(app.textFields.element(boundBy: 0), with: saved)
    try replace(app.textFields["Tags separated by commas"], with: "A, B")
    try activate(app.buttons["Save"])
    XCTAssertTrue(app.staticTexts[saved].waitForExistence(timeout: 10))
    try assertInvokingTileFocused(saved)
    try openEditor(tileTitle: saved)
    XCTAssertEqual(app.textFields.element(boundBy: 0).value as? String, saved)
    XCTAssertEqual(app.textFields["Tags separated by commas"].value as? String, "A, B")
    try replace(app.textFields.element(boundBy: 0), with: "Draft")
    try replace(app.textFields["Tags separated by commas"], with: "Draft")
    try activate(app.buttons["Cancel"])
    try assertInvokingTileFocused(saved)
    try openEditor(tileTitle: saved)
    XCTAssertEqual(app.textFields.element(boundBy: 0).value as? String, saved)
    XCTAssertEqual(app.textFields["Tags separated by commas"].value as? String, "A, B")
    XCUIRemote.shared.press(.menu)
    app.terminate(); app.launch()
    XCTAssertTrue(app.staticTexts[saved].waitForExistence(timeout: 20))
    try openEditor(tileTitle: saved)
    XCTAssertEqual(app.textFields["Tags separated by commas"].value as? String, "A, B")
    // Restore the isolated fixture for the next test/run through the real Save path.
    try replace(app.textFields.element(boundBy: 0), with: "")
    try replace(app.textFields["Tags separated by commas"], with: "")
    try activate(app.buttons["Save"])
    XCTAssertTrue(app.staticTexts[original].waitForExistence(timeout: 10))
  }

  func testEditorUsesFullScreenPresentation() throws {
    try openEditor(tileTitle: original)
    let field = app.textFields.element(boundBy: 0)
    let preview = app.images["Cover preview"]
    try require(NSPredicate { _, _ in field.hasFocus }, timeout: 5, evidence: "initial-title-focus-missing")
    XCTAssertGreaterThan(field.frame.width, app.frame.width * 0.4,
      "tvOS editor fields are constrained to a narrow sheet")
    XCTAssertLessThan(preview.frame.maxX, field.frame.minX,
      "Artwork and editable fields overlap")
    XCTAssertTrue(app.frame.contains(app.buttons["Save"].frame), "Save must remain visible")
    XCTAssertTrue(app.frame.contains(app.buttons["Cancel"].frame), "Cancel must remain visible")
    assertFocusedPromptReadable(field)
    record("fullscreen-library-editor")
    for (name, emptyField) in [("tags", app.textFields["Tags separated by commas"]),
                               ("cover-url", app.textFields["Cover image URL"])] {
      try focus(emptyField)
      XCTAssertTrue(app.frame.contains(emptyField.frame), "Focused field extends offscreen")
      assertFocusedPromptReadable(emptyField)
      record("fullscreen-empty-" + name)
    }
    XCUIRemote.shared.press(.menu)
    try assertInvokingTileFocused(original)
  }

  func testBackDiscardsDraftAndReturnsFocusToInvokingTile() throws {
    try openEditor(tileTitle: original)
    let originalTitle = editableValue(app.textFields.element(boundBy: 0))
    let originalTags = editableValue(app.textFields["Tags separated by commas"])
    try replace(app.textFields.element(boundBy: 0), with: "Back")
    try replace(app.textFields["Tags separated by commas"], with: "Back")
    record("back-ready-keyboard-absent-field-focused")
    XCUIRemote.shared.press(.menu)
    XCTAssertTrue(app.buttons["Save"].waitForNonExistence(timeout: 5))
    try assertInvokingTileFocused(original)
    try openEditor(tileTitle: original)
    XCTAssertEqual(editableValue(app.textFields.element(boundBy: 0)), originalTitle)
    XCTAssertEqual(editableValue(app.textFields["Tags separated by commas"]), originalTags)
    XCUIRemote.shared.press(.menu)
  }

  func testCoverURLSaveReopenAndClear() throws {
    let base = ProcessInfo.processInfo.environment["ICUBE_AUDIT_COVER_BASE_URL"] ?? "http://127.0.0.1:8765"
    try openEditor(tileTitle: original)
    try activate(app.buttons["Use Original Cover"])
    let originalPixels = try visibleCoverPixels()
    XCTAssertLessThan(magentaFraction(originalPixels), 0.10, "Original cover conflicts with fixture signature")
    try replace(app.textFields["Cover image URL"], with: base + "/audit-cover.png")
    try activate(app.buttons["Load Cover from URL"])
    let loaded = NSPredicate { _, _ in self.app.buttons["Save"].isEnabled }
    try require(loaded, timeout: 15, evidence: "cover-load-did-not-finish")
    XCTAssertGreaterThan(magentaFraction(try visibleCoverPixels()), 0.30, "Magenta/black fixture never rendered")
    record("cover-draft")
    try activate(app.buttons["Save"])
    try assertInvokingTileFocused(original)
    XCTAssertGreaterThan(magentaFraction(try renderedTilePixels()), 0.20, "Saved custom cover is hidden in the library card")
    record("cover-saved-tile")
    try openEditor(tileTitle: original)
    XCTAssertGreaterThan(magentaFraction(try visibleCoverPixels()), 0.30, "Saved fixture cover was not persisted")
    try activate(app.buttons["Use Original Cover"])
    try assertOriginalCover(originalPixels)
    try activate(app.buttons["Save"])
    try assertInvokingTileFocused(original)
    XCTAssertLessThan(magentaFraction(try renderedTilePixels()), 0.10, "Cleared artwork remained in the library card")
    record("cover-cleared-tile")
    try openEditor(tileTitle: original)
    try assertOriginalCover(originalPixels)
    XCUIRemote.shared.press(.menu)
  }

  func testOversizedCoverURLRejectedWithoutChangingDraft() throws {
    let base = ProcessInfo.processInfo.environment["ICUBE_AUDIT_COVER_BASE_URL"] ?? "http://127.0.0.1:8765"
    try openEditor(tileTitle: original)
    try activate(app.buttons["Use Original Cover"])
    let originalPixels = try visibleCoverPixels()
    try replace(app.textFields["Cover image URL"], with: base + "/oversized.png")
    try activate(app.buttons["Load Cover from URL"])
    XCTAssertTrue(app.staticTexts[CocoaError(.fileReadTooLarge).localizedDescription].waitForExistence(timeout: 10))
    record("oversized-cover-rejected")
    try assertOriginalCover(originalPixels)
    try activate(app.buttons["Cancel"])
    try assertInvokingTileFocused(original)
  }

  func testContextMenuSelectGamesSelectsOnceAndShortSelectOnlyTogglesSelection() throws {
    try focus(app.buttons["All Games"], direction: .down)
    XCUIRemote.shared.press(.right)
    try assertInvokingTileFocused(original)
    XCUIRemote.shared.press(.select, forDuration: 1.2)
    let select = app.cells.containing(.other, identifier: "Select Games").firstMatch
    XCTAssertTrue(select.waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["1 selected"].exists)
    try activate(select)
    XCTAssertTrue(app.staticTexts["1 selected"].waitForExistence(timeout: 5))
    try assertInvokingTileFocused(original)
    // Selection mode is established before this short press: it must only
    // deselect the fixture, never attempt to boot its intentionally inert bytes.
    XCUIRemote.shared.press(.select)
    XCTAssertFalse(app.staticTexts["1 selected"].exists)
    XCTAssertTrue(app.staticTexts[original].exists)
    record("selection-toggled-without-launch")
  }

  private func openEditor(tileTitle: String) throws {
    try checkBudget()
    guard app.staticTexts[tileTitle].waitForExistence(timeout: 10) else {
      record("fixture-tile-missing")
      XCTFail("Install only the non-executable audit fixture")
      throw AuditFailure.editor
    }
    XCUIRemote.shared.press(.left) // Re-enter the rail after a prior editor dismissal.
    try focus(app.buttons["All Games"], direction: .down)
    XCUIRemote.shared.press(.right)
    try assertInvokingTileFocused(tileTitle)
    // A short select would attempt emulation. Long select must expose the real context action.
    XCUIRemote.shared.press(.select, forDuration: 1.2)
    let edit = app.cells.containing(.other, identifier: "Edit Library Details").firstMatch
    guard edit.waitForExistence(timeout: 5) else {
      record("editor-entry-unreachable")
      XCTFail("Long Select did not expose the native Edit Library Details menu cell")
      throw AuditFailure.editor
    }
    XCTAssertFalse(app.staticTexts["1 selected"].exists, "Opening the menu unexpectedly selected the game")
    try activate(edit)
    XCTAssertTrue(app.textFields["Tags separated by commas"].waitForExistence(timeout: 10))
    let ready = NSPredicate { _, _ in self.app.buttons["Save"].isEnabled }
    try require(ready, timeout: 10, evidence: "editor-not-ready")
  }

  private func replace(_ field: XCUIElement, with text: String) throws {
    try focus(field)
    XCUIRemote.shared.press(.select)
    // A persisted custom title can equal its placeholder. Raw length plus one
    // safely clears both a real value and a placeholder-only empty field.
    let old = field.value as? String ?? ""
    guard old.count <= 80, text.count <= 120 else {
      record("unexpected-long-field"); XCTFail("Unexpected fixture field length"); throw AuditFailure.keyboard
    }
    let observedKeyboard = app.keyboards.count > 0 || app.keys.count > 0
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 1) + text)
    if !observedKeyboard && app.keyboards.count == 0 && app.keys.count == 0 {
      record("keyboard-AX-not-observed")
      // Keep the diagnostic: completion is still gated on positive field-focus
      // restoration and repeated absence of both keyboard and key AX nodes.
    }
    XCUIRemote.shared.press(.menu) // Dismiss only the text-entry keyboard.
    var settledSamples = 0
    let settled = NSPredicate { _, _ in
      let ready = self.app.keyboards.count == 0 && self.app.keys.count == 0
        && self.app.buttons["Save"].exists && self.isFocused(field)
        && self.editableValue(field) == text
      settledSamples = ready ? settledSamples + 1 : 0
      return settledSamples >= 2
    }
    try require(settled, timeout: 6, evidence: "keyboard-dismissal-unsettled")
    XCTAssertEqual(editableValue(field), text, "Text entry did not produce the intended draft")
  }

  private func activate(_ element: XCUIElement) throws {
    try focus(element)
    XCTAssertTrue(element.isEnabled)
    XCUIRemote.shared.press(.select)
  }

  private func focus(_ element: XCUIElement, direction: XCUIRemote.Button = .down) throws {
    try checkBudget()
    guard element.waitForExistence(timeout: 3) else {
      record("focus-target-missing"); XCTFail("Focus target missing: \(element)"); throw AuditFailure.focus
    }
    let deadline = Date().addingTimeInterval(12)
    for _ in 0..<16 {
      if isFocused(element) { return }
      if Date() >= deadline { break }
      let target = focusOwner(element).frame
      let current = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
      var movement = direction
      if current.exists, target.width > 0, target.height > 0 {
        let origin = current.frame
        if target.minX >= origin.maxX { movement = .right }
        else if target.maxX <= origin.minX { movement = .left }
        else if abs(target.midY - origin.midY) > 20 { movement = target.midY < origin.midY ? .up : .down }
        else if abs(target.midX - origin.midX) > 20 { movement = target.midX < origin.midX ? .left : .right }
      }
      XCUIRemote.shared.press(movement)
    }
    record("focus-failure")
    XCTFail("Could not focus \(element.label)")
    throw AuditFailure.focus
  }

  private func focusOwner(_ element: XCUIElement) -> XCUIElement {
    if element.elementType == .button, !element.label.isEmpty {
      let owner = app.cells.containing(.button, identifier: element.label).firstMatch
      if owner.exists { return owner }
    }
    return element
  }

  private func isFocused(_ element: XCUIElement) -> Bool {
    guard element.exists else { return false }
    if element.hasFocus || focusOwner(element).hasFocus { return true }
    return element.elementType == .cell && element.descendants(matching: .any)
      .matching(NSPredicate(format: "hasFocus == true")).count > 0
  }

  private func editableValue(_ field: XCUIElement) -> String {
    let value = field.value as? String ?? ""
    return value == field.placeholderValue ? "" : value
  }

  private func require(_ predicate: NSPredicate, timeout: TimeInterval, evidence: String) throws {
    try checkBudget()
    let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout)
    guard result == .completed else {
      record(evidence); XCTFail("Unsettled UI: \(evidence)"); throw AuditFailure.editor
    }
  }

  private func checkBudget() throws {
    if Date().timeIntervalSince(caseStarted) >= 165 {
      record("case-time-budget-exhausted"); XCTFail("Audit exceeded its 165-second action budget")
      throw AuditFailure.deadline
    }
  }

  private func assertInvokingTileFocused(_ title: String) throws {
    let focused = NSPredicate { _, _ in
      // SwiftUI reports card focus on its final accessibility leaf (the
      // platform subtitle). Require that leaf to belong to this title's card,
      // excluding screen-sized ancestors that contain every library item.
      self.app.otherElements.containing(.staticText, identifier: title).allElementsBoundByIndex
        .filter { $0.frame.width < self.app.frame.width / 2 && $0.frame.height < self.app.frame.height }
        .contains { $0.hasFocus || $0.descendants(matching: .any)
          .matching(NSPredicate(format: "hasFocus == true")).count > 0 }
    }
    let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: nil)], timeout: 10)
    record("tile-focus-" + title)
    XCTAssertEqual(result, .completed, "Invoking tile did not receive focus")
    if result != .completed { throw AuditFailure.focus }
  }

  private func record(_ name: String) {
    print("LIBRARY EDIT AUDIT \(name)\n\(app.debugDescription)")
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name; attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func renderedTilePixels() throws -> [UInt8] {
    let cards = app.otherElements.containing(.staticText, identifier: original).allElementsBoundByIndex
      .filter { $0.frame.width < app.frame.width / 2 && $0.frame.height > 200 && $0.frame.height < app.frame.height }
    guard let card = cards.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
      record("library-card-missing"); XCTFail("Library artwork card missing"); throw AuditFailure.artwork
    }
    return pixels(card)
  }

  private func visibleCoverPixels() throws -> [UInt8] {
    let image = app.images["Cover preview"]
    var previous: CGRect?
    var stable = 0
    let visible = NSPredicate { _, _ in
      guard image.exists else { return false }
      let frame = image.frame
      let contained = frame.width >= 100 && frame.height >= 100 && self.app.frame.contains(frame)
      stable = contained && previous == frame ? stable + 1 : 0
      previous = frame
      return stable >= 2
    }
    try require(visible, timeout: 5, evidence: "cover-not-fully-visible-and-settled")
    return pixels(image)
  }

  private func magentaFraction(_ bytes: [UInt8]) -> Double {
    guard bytes.count == 32 * 32 * 4 else { return 0 }
    let count = stride(from: 0, to: bytes.count, by: 4).filter {
      let red = Int(bytes[$0]), green = Int(bytes[$0 + 1]), blue = Int(bytes[$0 + 2])
      return red > 100 && blue > 100 && green < 80 && abs(red - blue) < 70
    }.count
    return Double(count) / Double(32 * 32)
  }

  private func assertOriginalCover(_ originalPixels: [UInt8]) throws {
    let restored = try visibleCoverPixels()
    XCTAssertLessThan(magentaFraction(restored), 0.10, "Fixture artwork remained after clear")
    guard restored.count == originalPixels.count, !restored.isEmpty else {
      XCTFail("Missing original/restored preview pixels"); throw AuditFailure.artwork
    }
    let channels = restored.indices.filter { $0 % 4 != 3 }
    let difference = channels.reduce(0) { $0 + abs(Int(restored[$1]) - Int(originalPixels[$1])) }
    // Same fully-visible, focused cell and normalized sample. A small allowance
    // covers display rounding, while fixture presence is independently rejected.
    XCTAssertLessThanOrEqual(Double(difference) / Double(channels.count), 6,
      "Cleared artwork does not match the original rendered preview")
  }

  private func assertFocusedPromptReadable(_ field: XCUIElement) {
    let sample = pixels(field, width: 256, height: 64)
    guard sample.count == 256 * 64 * 4 else { XCTFail("Missing focused prompt pixels"); return }
    var dark = 0
    var light = 0
    // Exclude the pill corners/border; inspect glyphs on its central light surface.
    for y in 16..<48 {
      for x in 13..<243 {
        let offset = (y * 256 + x) * 4
        if sample[offset] < 100 && sample[offset + 1] < 100 && sample[offset + 2] < 120 { dark += 1 }
        if sample[offset] > 210 && sample[offset + 1] > 210 && sample[offset + 2] > 210 { light += 1 }
      }
    }
    XCTAssertGreaterThan(light, 230 * 32 / 2, "Expected native light focus surface")
    XCTAssertGreaterThan(dark, 8, "Focused empty prompt is washed out against its light surface")
  }

  private func pixels(_ element: XCUIElement, width: Int = 32, height: Int = 32) -> [UInt8] {
    // Compare rendered pixels, avoiding PNG container/compression differences.
    guard let image = element.screenshot().image.cgImage else { XCTFail("No preview pixels"); return [] }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { storage in
      let context = CGContext(data: storage.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return bytes
  }
}
