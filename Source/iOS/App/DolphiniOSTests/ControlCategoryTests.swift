// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

/// Which Buttons section each control lands in, and the titles that say which group a row belongs
/// to. Control orders are the core's `AddInput` lists (GCPadEmu.cpp, WiimoteEmu.cpp, Nunchuk.cpp,
/// Classic.cpp), as the bridges report them.
final class ControlCategoryTests: XCTestCase {

  private func rows(_ owner: RemapGroupOwner, _ group: Int, _ names: [String]) -> [RemapControlRow] {
    names.enumerated().map { RemapControlRow(owner: owner, groupId: group, index: $0.offset, name: $0.element, expression: "") }
  }

  private func categories(_ rows: [RemapControlRow]) -> [ControlCategory?] {
    rows.map { ControlCategory.of(owner: $0.owner, groupId: $0.groupId, index: $0.index) }
  }

  func test_gameCubeButtons_faceThenZThenStart() {
    XCTAssertEqual(
      categories(rows(.gcPad, 0, ["A", "B", "X", "Y", "Z", "START"])),
      [.face, .face, .face, .face, .triggers, .system])
  }

  func test_gameCubeGroups() {
    XCTAssertEqual(ControlCategory.of(owner: .gcPad, groupId: 1, index: 0), .sticks)
    XCTAssertEqual(ControlCategory.of(owner: .gcPad, groupId: 2, index: 0), .sticks)
    XCTAssertEqual(ControlCategory.of(owner: .gcPad, groupId: 3, index: 0), .dPad)
    XCTAssertEqual(ControlCategory.of(owner: .gcPad, groupId: 4, index: 2), .triggers)
  }

  /// Rumble is an output: capture polls inputs, so it has nothing to bind there. Options groups
  /// hold settings only. Both stay editable as raw expressions under Advanced.
  func test_rumbleAndOptionsAreNotButtons() {
    XCTAssertNil(ControlCategory.of(owner: .gcPad, groupId: 5, index: 0))
    XCTAssertNil(ControlCategory.of(owner: .gcPad, groupId: 7, index: 0))
    XCTAssertNil(ControlCategory.of(owner: .wiimote, groupId: 6, index: 0))
    XCTAssertNil(ControlCategory.of(owner: .wiimote, groupId: 8, index: 0))
  }

  func test_wiiRemoteButtons_faceThenMinusPlusHome() {
    XCTAssertEqual(
      categories(rows(.wiimote, 0, ["A", "B", "1", "2", "-", "+", "HOME"])),
      [.face, .face, .face, .face, .system, .system, .system])
  }

  func test_wiiRemoteMotionGroups() {
    for group in [2, 3, 4, 5] {
      XCTAssertEqual(ControlCategory.of(owner: .wiimote, groupId: group, index: 0), .motion, "group \(group)")
    }
  }

  func test_nunchuk_cAndZAreTriggers_stickIsSticks_restIsMotion() {
    XCTAssertEqual(categories(rows(.nunchuk, 0, ["C", "Z"])), [.triggers, .triggers])
    XCTAssertEqual(ControlCategory.of(owner: .nunchuk, groupId: 1, index: 0), .sticks)
    XCTAssertEqual(ControlCategory.of(owner: .nunchuk, groupId: 4, index: 0), .motion)
  }

  func test_classicButtons() {
    XCTAssertEqual(
      categories(rows(.classic, 0, ["A", "B", "X", "Y", "ZL", "ZR", "-", "+", "HOME"])),
      [.face, .face, .face, .face, .triggers, .triggers, .system, .system, .system])
    XCTAssertEqual(ControlCategory.of(owner: .classic, groupId: 1, index: 0), .triggers)
    XCTAssertEqual(ControlCategory.of(owner: .classic, groupId: 2, index: 0), .dPad)
    XCTAssertEqual(ControlCategory.of(owner: .classic, groupId: 4, index: 0), .sticks)
  }

  func test_titlesNameTheirGroup() {
    XCTAssertEqual(ControlCategory.title(for: rows(.gcPad, 1, ["Up"])[0]), "Control Stick Up")
    XCTAssertEqual(ControlCategory.title(for: rows(.gcPad, 2, ["Up"])[0]), "C-Stick Up")
    XCTAssertEqual(ControlCategory.title(for: rows(.wiimote, 3, ["Recenter"])[0]), "Pointer Recenter")
    XCTAssertEqual(ControlCategory.title(for: rows(.classic, 0, ["A"])[0]), "Classic A", "a Wii Remote + Classic has two A buttons")
    XCTAssertEqual(ControlCategory.title(for: rows(.nunchuk, 0, ["C"])[0]), "Nunchuk C")
    XCTAssertEqual(ControlCategory.title(for: rows(.wiimote, 0, ["A"])[0]), "A", "the Wii Remote's own buttons keep their printed name")
  }

  /// The size the spec's "one row per control" reaches for a Wii Remote + Classic Controller, with
  /// the real control counts: 59 capture rows, plus Rumble only under Advanced.
  func test_wiiRemotePlusClassic_groupsInto59Rows() {
    let names = { (count: Int) in (0 ..< count).map { "c\($0)" } }
    let wii = rows(.wiimote, 0, names(7)) + rows(.wiimote, 1, names(4)) + rows(.wiimote, 3, names(7))
      + rows(.wiimote, 5, names(6)) + rows(.wiimote, 4, names(5)) + rows(.wiimote, 2, names(3)) + rows(.wiimote, 6, names(1))
    let classic = rows(.classic, 0, names(9)) + rows(.classic, 2, names(4)) + rows(.classic, 3, names(5))
      + rows(.classic, 4, names(5)) + rows(.classic, 1, names(4))
    let grouped = ControlCategory.grouped(wii + classic)
    XCTAssertEqual(grouped.map { $0.category }, [.face, .dPad, .sticks, .triggers, .system, .motion])
    XCTAssertEqual(grouped.map { $0.rows.count }, [8, 8, 10, 6, 6, 21])
    XCTAssertEqual(grouped.map { $0.rows.count }.reduce(0, +), 59)
  }

  func test_grouped_keepsTheGivenOrderInsideACategory_andDropsEmptyOnes() {
    let controls = rows(.gcPad, 3, ["Up", "Down"]) + rows(.gcPad, 0, ["A"])
    let grouped = ControlCategory.grouped(controls)
    XCTAssertEqual(grouped.map { $0.category }, [.face, .dPad])
    XCTAssertEqual(grouped[1].rows.map(\.name), ["Up", "Down"])
  }
}
