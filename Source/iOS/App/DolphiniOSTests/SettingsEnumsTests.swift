// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class SettingsEnumsTests: XCTestCase {
  func test_region_selectableExcludesTheErrorPlaceholder_andKeepsTheRawValues() {
    XCTAssertEqual(Region.selectable, [.ntscJ, .ntscU, .pal, .ntscK])
    XCTAssertEqual(Region.ntscJ.rawValue, 0); XCTAssertEqual(Region.ntscU.rawValue, 1); XCTAssertEqual(Region.pal.rawValue, 2)
    XCTAssertEqual(Region.unknown.rawValue, 3); XCTAssertEqual(Region.ntscK.rawValue, 4)
  }

  func test_region_unknownRawValuesReadAsTheErrorCase() {
    for raw in [3, 5, -1, 99] { XCTAssertEqual(Region.from(raw: raw), .unknown, "raw \(raw)") }
    XCTAssertEqual(Region.unknown.label, "Error")
  }

  func test_libraryBackgroundStyle_unsetOrUnknownStoredValueIsGradient() {
    XCTAssertEqual(LibraryBackgroundStyle.from(stored: nil), .gradient)
    XCTAssertEqual(LibraryBackgroundStyle.from(stored: "bogus"), .gradient)
    for style in LibraryBackgroundStyle.allCases { XCTAssertEqual(LibraryBackgroundStyle.from(stored: style.rawValue), style) }
  }

  func test_horizontalMotionMode_rawValuesAndLabels() {
    XCTAssertEqual(HorizontalMotionMode.roll.rawValue, 0)
    XCTAssertEqual(HorizontalMotionMode.yaw.rawValue, 1)
    XCTAssertFalse(HorizontalMotionMode.roll.label.isEmpty)
    XCTAssertFalse(HorizontalMotionMode.yaw.description.isEmpty)
  }
}
