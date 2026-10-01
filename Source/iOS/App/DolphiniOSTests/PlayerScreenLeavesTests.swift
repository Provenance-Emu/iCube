// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

/// The three screens the player screen pushes: Device, Load Profile and the raw-expression editor.
/// Each is a `MenuScreen` over a pure builder, so Back works from a pad (B) and the Siri Remote
/// (Menu), and one pick is one action.
final class PlayerScreenLeavesTests: XCTestCase {

  private static let xbox = "MFi/0/Xbox Wireless Controller"

  // MARK: Device (decision 9)

  private var deviceOptions: [DeviceOption] {
    [
      DeviceOption(choice: .noDevice, title: "None"),
      DeviceOption(choice: .touchscreen, title: "Touchscreen"),
      DeviceOption(choice: .pad(Self.xbox), title: "Xbox Wireless Controller"),
    ]
  }

  func test_devices_markTheCurrentOne() {
    let model = DeviceListModelBuilder.make(options: deviceOptions, current: .touchscreen, onPick: { _ in })
    XCTAssertEqual(model.allItems.map(\.id), ["device-none", "device-touchscreen", "device-\(Self.xbox)"])
    XCTAssertEqual(model.item(id: "device-touchscreen")?.badge, "Current")
    XCTAssertNil(model.item(id: "device-none")?.badge)
  }

  /// One pick, one assignment: the row's action reports exactly the choice it shows.
  func test_devices_pickReportsThatChoiceOnce() {
    var picks: [PlayerDeviceChoice] = []
    let model = DeviceListModelBuilder.make(options: deviceOptions, current: .noDevice, onPick: { picks.append($0) })
    guard let item = model.item(id: "device-\(Self.xbox)"), case .action(let action) = item.role else {
      return XCTFail("not an action")
    }
    action()
    XCTAssertEqual(picks, [.pad(Self.xbox)])
  }

  /// Rows, not a picker: a pad's A or d-pad never steps through devices.
  func test_devices_areActionRows() {
    let model = DeviceListModelBuilder.make(options: deviceOptions, current: .noDevice, onPick: { _ in })
    for item in model.allItems {
      guard case .action = item.role else { return XCTFail("\(item.id) is not a plain action row") }
    }
  }

  // MARK: Load Profile

  func test_profiles_sortedCaseInsensitively_currentMarked() {
    let model = ProfileListModelBuilder.make(names: ["touchscreen", "Physical Controller", "DSU"], current: "DSU", onPick: { _ in })
    XCTAssertEqual(model.allItems.map(\.id), ["profile-DSU", "profile-Physical Controller", "profile-touchscreen"])
    XCTAssertEqual(model.item(id: "profile-DSU")?.badge, "Current")
    XCTAssertNil(model.item(id: "profile-touchscreen")?.badge)
  }

  func test_profiles_pickRunsOnPickWithThatName() {
    var picked: String?
    let model = ProfileListModelBuilder.make(names: ["DSU"], current: nil, onPick: { picked = $0 })
    guard let item = model.item(id: "profile-DSU"), case .action(let action) = item.role else { return XCTFail("not an action") }
    action()
    XCTAssertEqual(picked, "DSU")
  }

  /// An enabled no-op row, so tvOS focus has somewhere to land and Menu still pops.
  func test_profiles_noneSaysSo() {
    let model = ProfileListModelBuilder.make(names: [], current: nil, onPick: { _ in })
    XCTAssertEqual(model.focusableIDs, ["no-profiles"])
  }

  // MARK: Expression editor

  private let valid = ExpressionCheck(status: .valid, message: "The expression is valid.")
  private let invalid = ExpressionCheck(status: .invalid, message: "Not saved: Expected closing paren.")

  private func editor(text: String, original: String, check: ExpressionCheck) -> MenuModel {
    ExpressionEditorModelBuilder.make(
      text: .constant(text), original: original, check: check, onSave: {}, onRevert: {}, onClear: {})
  }

  /// An untouched expression is never re-validated or rewritten: a legacy bareword can parse as a
  /// syntax error yet still work (ExpressionParser.cpp:1119-1124).
  func test_untouched_cannotBeSavedOrReverted_andIsNotJudged() {
    let model = editor(text: "`Button A`", original: "`Button A`", check: invalid)
    XCTAssertEqual(model.item(id: "expression-save")?.isEnabled, false)
    XCTAssertEqual(model.item(id: "expression-revert")?.isEnabled, false)
    XCTAssertEqual(model.item(id: "expression-check")?.title, "Edit the expression, then Save.")
  }

  func test_editedAndValid_canBeSaved() {
    let model = editor(text: "`Button B`", original: "`Button A`", check: valid)
    XCTAssertEqual(model.item(id: "expression-save")?.isEnabled, true)
    XCTAssertEqual(model.item(id: "expression-revert")?.isEnabled, true)
    XCTAssertEqual(model.item(id: "expression-check")?.title, "The expression is valid.")
  }

  /// Spec edge case: "Show the parser's error inline and do not save."
  func test_editedAndInvalid_showsTheErrorAndCannotBeSaved() {
    let model = editor(text: "(`Button B`", original: "`Button A`", check: invalid)
    XCTAssertEqual(model.item(id: "expression-save")?.isEnabled, false)
    XCTAssertEqual(model.item(id: "expression-check")?.title, "Not saved: Expected closing paren.")
  }

  /// Clear is the pad's way to unbind (a pad cannot long-press a capture row).
  func test_clear_isOffWhenTheTextIsAlreadyEmpty() {
    XCTAssertEqual(editor(text: "", original: "`Button A`", check: valid).item(id: "expression-clear")?.isEnabled, false)
    XCTAssertEqual(editor(text: "`Button A`", original: "`Button A`", check: valid).item(id: "expression-clear")?.isEnabled, true)
  }
}
