// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if DEBUG
import XCTest

@testable import iCube

/// `-ICubePauseFocus` parsing, used by Scripts/tvos_screens.sh to capture a focused save-slot tile.
final class PauseMenuDebugFocusTests: XCTestCase {
  func testNamedFields() {
    XCTAssertEqual(PauseMenuView.debugFocusField("back"), .back)
    XCTAssertEqual(PauseMenuView.debugFocusField("save"), .save)
    XCTAssertEqual(PauseMenuView.debugFocusField("load"), .load)
    XCTAssertEqual(PauseMenuView.debugFocusField("filmstrip"), .filmstrip)
  }

  func testSlotsUseTheUINumbering() {
    XCTAssertEqual(PauseMenuView.debugFocusField("slot-1"), .slot(1))
    XCTAssertEqual(PauseMenuView.debugFocusField("slot-10"), .slot(10))
  }

  func testUnknownOrOutOfRangeIsNil() {
    XCTAssertNil(PauseMenuView.debugFocusField(nil))
    XCTAssertNil(PauseMenuView.debugFocusField("slot-0"))
    XCTAssertNil(PauseMenuView.debugFocusField("slot-11"))
    XCTAssertNil(PauseMenuView.debugFocusField("slot-x"))
    XCTAssertNil(PauseMenuView.debugFocusField("tile"))
  }
}
#endif
