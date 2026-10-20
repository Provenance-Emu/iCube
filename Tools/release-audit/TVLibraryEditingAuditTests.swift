// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import UIKit

/// External, rendered tvOS acceptance suite. Requires the isolated fixture recipe
/// in tvos-library-editing.md. Never selects a library tile with a short press.
final class TVLibraryEditingAuditTests: XCTestCase {
  private let original = "ICube Library Edit Audit NEVER LAUNCH"
  private let saved = "Audit Custom Title"
  private var app: XCUIApplication!
  private enum AuditFailure: Error { case focus, editor }

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
    app = XCUIApplication(bundleIdentifier: "com.joemattiello.iCube-debug")
    // Demo entries intentionally have no editor. Override any prior demo default.
    app.launchArguments = ["-SCREENSHOT_MODE", "0", "-onboarding_seen_v1", "YES",
      "-ICubeAppearance", "dark", "-library_platform_filter", "all", "-AppleLanguages", "(en)"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
  }

  override func tearDown() {
    app?.terminate()
    super.tearDown()
  }

  func testTitleTagsSaveCancelReopenAndRelaunch() throws {
    try openEditor(tileTitle: original)
    try replace(app.textFields.element(boundBy: 0), with: saved)
    try replace(app.textFields["Tags separated by commas"], with: "Audit Action, Audit Puzzle")
    try activate(app.buttons["Save"])
    XCTAssertTrue(app.staticTexts[saved].waitForExistence(timeout: 10))
    try assertInvokingTileFocused(saved)
    try openEditor(tileTitle: saved)
    XCTAssertEqual(app.textFields.element(boundBy: 0).value as? String, saved)
    XCTAssertEqual(app.textFields["Tags separated by commas"].value as? String, "Audit Action, Audit Puzzle")
    try replace(app.textFields.element(boundBy: 0), with: "UNSAVED TITLE")
    try replace(app.textFields["Tags separated by commas"], with: "UNSAVED TAG")
    try activate(app.buttons["Cancel"])
    try assertInvokingTileFocused(saved)
    try openEditor(tileTitle: saved)
    XCTAssertEqual(app.textFields.element(boundBy: 0).value as? String, saved)
    XCTAssertEqual(app.textFields["Tags separated by commas"].value as? String, "Audit Action, Audit Puzzle")
    XCUIRemote.shared.press(.menu)
    app.terminate(); app.launch()
    XCTAssertTrue(app.staticTexts[saved].waitForExistence(timeout: 20))
    try openEditor(tileTitle: saved)
    XCTAssertEqual(app.textFields["Tags separated by commas"].value as? String, "Audit Action, Audit Puzzle")
    // Restore the isolated fixture for the next test/run through the real Save path.
    try replace(app.textFields.element(boundBy: 0), with: "")
    try replace(app.textFields["Tags separated by commas"], with: "")
    try activate(app.buttons["Save"])
    XCTAssertTrue(app.staticTexts[original].waitForExistence(timeout: 10))
  }

  func testBackDiscardsDraftAndReturnsFocusToInvokingTile() throws {
    try openEditor(tileTitle: original)
    try replace(app.textFields.element(boundBy: 0), with: "BACK MUST DISCARD")
    try replace(app.textFields["Tags separated by commas"], with: "BACK MUST DISCARD")
    XCUIRemote.shared.press(.menu)
    XCTAssertFalse(app.buttons["Save"].exists)
    try assertInvokingTileFocused(original)
    try openEditor(tileTitle: original)
    XCTAssertNotEqual(app.textFields.element(boundBy: 0).value as? String, "BACK MUST DISCARD")
    XCTAssertNotEqual(app.textFields["Tags separated by commas"].value as? String, "BACK MUST DISCARD")
    XCUIRemote.shared.press(.menu)
  }

  func testCoverURLSaveReopenClearAndOversizedFailure() throws {
    let base = ProcessInfo.processInfo.environment["ICUBE_AUDIT_COVER_BASE_URL"] ?? "http://127.0.0.1:8765"
    try openEditor(tileTitle: original)
    let preview = app.images["Cover preview"]
    XCTAssertTrue(preview.waitForExistence(timeout: 10))
    try activate(app.buttons["Use Original Cover"])
    let originalPixels = pixels(preview)
    try replace(app.textFields["Cover image URL"], with: base + "/audit-cover.png")
    try activate(app.buttons["Load Cover from URL"])
    XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 20))
    let loaded = NSPredicate { _, _ in self.app.buttons["Save"].isEnabled }
    expectation(for: loaded, evaluatedWith: nil)
    waitForExpectations(timeout: 30)
    XCTAssertNotEqual(pixels(preview), originalPixels, "Cover never rendered")
    record("cover-draft")
    try activate(app.buttons["Save"])
    try assertInvokingTileFocused(original)
    record("cover-saved-tile")
    try openEditor(tileTitle: original)
    XCTAssertNotEqual(pixels(preview), originalPixels, "Cover was not persisted")
    try replace(app.textFields["Cover image URL"], with: base + "/oversized.png")
    try activate(app.buttons["Load Cover from URL"])
    XCTAssertTrue(app.staticTexts[CocoaError(.fileReadTooLarge).localizedDescription].waitForExistence(timeout: 20),
      "Expected a visible bounded-download error")
    record("oversized-cover-rejected")
    try activate(app.buttons["Use Original Cover"])
    XCTAssertEqual(pixels(preview), originalPixels, "Clear did not redraw original cover")
    try activate(app.buttons["Save"])
    try assertInvokingTileFocused(original)
    record("cover-cleared-tile")
    try openEditor(tileTitle: original)
    XCTAssertEqual(pixels(preview), originalPixels, "Cleared cover returned after reopen")
    XCUIRemote.shared.press(.menu)
  }

  private func openEditor(tileTitle: String) throws {
    XCTAssertTrue(app.staticTexts[tileTitle].waitForExistence(timeout: 20), "Install only the non-executable audit fixture")
    try focus(app.buttons["All Games"], direction: .up)
    XCUIRemote.shared.press(.right)
    try assertInvokingTileFocused(tileTitle)
    // A short select would attempt emulation. Long select must expose the real context action.
    XCUIRemote.shared.press(.select, forDuration: 1.2)
    let edit = app.buttons["Edit Library Details"]
    guard edit.waitForExistence(timeout: 5) else {
      record("editor-entry-unreachable")
      XCTFail("Long Select did not expose Edit Library Details (check selection gesture/context-menu conflict)")
      throw AuditFailure.editor
    }
    try activate(edit)
    XCTAssertTrue(app.textFields["Tags separated by commas"].waitForExistence(timeout: 10))
    let ready = NSPredicate { _, _ in self.app.buttons["Save"].isEnabled }
    expectation(for: ready, evaluatedWith: nil)
    waitForExpectations(timeout: 30)
  }

  private func replace(_ field: XCUIElement, with text: String) throws {
    try focus(field)
    XCUIRemote.shared.press(.select)
    let old = field.value as? String ?? ""
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 1) + text)
    XCUIRemote.shared.press(.menu) // Dismiss only the text-entry keyboard.
    XCTAssertTrue(app.buttons["Save"].exists, "Keyboard Back unexpectedly dismissed editor")
  }

  private func activate(_ element: XCUIElement) throws {
    try focus(element)
    XCTAssertTrue(element.isEnabled)
    XCUIRemote.shared.press(.select)
  }

  private func focus(_ element: XCUIElement, direction: XCUIRemote.Button = .down) throws {
    XCTAssertTrue(element.waitForExistence(timeout: 10))
    for movement in [direction, direction == .down ? .up : .down] {
      for _ in 0..<40 {
        if element.hasFocus { return }
        XCUIRemote.shared.press(movement)
      }
    }
    record("focus-failure")
    XCTFail("Could not focus \(element.label)")
    throw AuditFailure.focus
  }

  private func assertInvokingTileFocused(_ title: String) throws {
    let focused = NSPredicate { _, _ in
      self.app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true"))
        .allElementsBoundByIndex.contains { $0.label.contains(title) || $0.staticTexts[title].exists }
    }
    expectation(for: focused, evaluatedWith: nil)
    waitForExpectations(timeout: 10)
    record("tile-focus-" + title)
  }

  private func record(_ name: String) {
    print("LIBRARY EDIT AUDIT \(name)\n\(app.debugDescription)")
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name; attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func pixels(_ element: XCUIElement) -> [UInt8] {
    // Compare rendered pixels, avoiding PNG container/compression differences.
    guard let image = element.screenshot().image.cgImage else { XCTFail("No preview pixels"); return [] }
    var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
    bytes.withUnsafeMutableBytes { storage in
      let context = CGContext(data: storage.baseAddress, width: 32, height: 32,
        bitsPerComponent: 8, bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
    }
    return bytes
  }
}
