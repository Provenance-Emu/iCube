// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

/// Covers `SaveStateFormatting.gameTimeString(seconds:)`, the pure duration
/// formatter behind the "game-time" field on each save-state card
/// (`SaveStateCardView`, part of the D10 pause-menu grid redesign).
final class SaveStateFormattingTests: XCTestCase {
  func testNilForMissingValue() {
    XCTAssertNil(SaveStateFormatting.gameTimeString(seconds: nil))
  }

  func testNilForNegativeValue() {
    XCTAssertNil(SaveStateFormatting.gameTimeString(seconds: -1))
  }

  func testNilForNonFiniteValue() {
    XCTAssertNil(SaveStateFormatting.gameTimeString(seconds: .infinity))
    XCTAssertNil(SaveStateFormatting.gameTimeString(seconds: .nan))
  }

  func testZeroFormatsAsZero() {
    XCTAssertEqual(SaveStateFormatting.gameTimeString(seconds: 0), "00:00")
  }

  func testUnderAnHourOmitsHourComponent() {
    // 12 minutes, 3 seconds
    XCTAssertEqual(SaveStateFormatting.gameTimeString(seconds: 12 * 60 + 3), "12:03")
  }

  func testAtLeastAnHourIncludesHourComponent() {
    // 1 hour, 24 minutes, 7 seconds. DateComponentsFormatter's .positional
    // style with .pad zero-pads every component, including the leading one
    // (verified empirically: 5047 -> "01:24:07", not "1:24:07").
    let seconds: Double = 1 * 3600 + 24 * 60 + 7
    XCTAssertEqual(SaveStateFormatting.gameTimeString(seconds: seconds), "01:24:07")
  }

  func testJustUnderAnHourStillOmitsHourComponent() {
    XCTAssertEqual(SaveStateFormatting.gameTimeString(seconds: 3599), "59:59")
  }

  func testExactlyAnHourIncludesHourComponent() {
    XCTAssertEqual(SaveStateFormatting.gameTimeString(seconds: 3600), "01:00:00")
  }
}
