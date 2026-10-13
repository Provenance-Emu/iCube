// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// The tvOS Save States pane's pure parts: `-ICubePauseFocus` parsing (Scripts/tvos_screens.sh captures a
/// focused slot with it) and which state each slot card shows.
final class TVSaveSlotsPaneTests: XCTestCase {
  func testDebugFocusSlotsUseTheUINumbering() {
    XCTAssertEqual(TVSaveSlotsPane.debugFocus("slot-1"), .slot(1))
    XCTAssertEqual(TVSaveSlotsPane.debugFocus("slot-10"), .slot(10))
    XCTAssertEqual(TVSaveSlotsPane.debugFocus("view-all"), .viewAll)
  }

  func testDebugFocusUnknownOrOutOfRangeIsNil() {
    XCTAssertNil(TVSaveSlotsPane.debugFocus(nil))
    XCTAssertNil(TVSaveSlotsPane.debugFocus("slot-0"))
    XCTAssertNil(TVSaveSlotsPane.debugFocus("slot-11"))
    XCTAssertNil(TVSaveSlotsPane.debugFocus("slot-x"))
    XCTAssertNil(TVSaveSlotsPane.debugFocus("back"))
  }

  func testLatestBySlotKeepsTheNewestStatePerSlot() {
    let older = state(slot: 2, modified: 100)
    let newer = state(slot: 2, modified: 200)
    let other = state(slot: 5, modified: 50)
    let bySlot = TVSaveSlotsPane.latestBySlot([older, other, newer])
    XCTAssertEqual(bySlot[2]?.id, newer.id)
    XCTAssertEqual(bySlot[5]?.id, other.id)
    XCTAssertEqual(bySlot.count, 2)
  }

  func testLatestBySlotSkipsTheAutoStateAndSlotlessStates() {
    let auto = state(slot: 1, modified: 300, isAuto: true)
    let slotless = state(slot: nil, modified: 300)
    XCTAssertTrue(TVSaveSlotsPane.latestBySlot([auto, slotless]).isEmpty)
  }

  func testLatestBySlotFallsBackToCreatedAt() {
    let created = state(slot: 3, modified: nil, created: 500)
    let modified = state(slot: 3, modified: 400)
    XCTAssertEqual(TVSaveSlotsPane.latestBySlot([modified, created])[3]?.id, created.id)
  }

  private func state(slot: Int?, modified: TimeInterval?, created: TimeInterval? = nil, isAuto: Bool = false) -> SaveStateInfo {
    SaveStateInfo(gameID: "GALE01", displayName: "State", slot: slot,
                  createdAt: created.map(Date.init(timeIntervalSince1970:)),
                  modifiedAt: modified.map(Date.init(timeIntervalSince1970:)),
                  sizeBytes: nil, versionHash: nil, isCompatible: true,
                  path: URL(fileURLWithPath: "/tmp/GALE01.s0\(slot ?? 0)"), thumbnailURL: nil, isAuto: isAuto)
  }
}
