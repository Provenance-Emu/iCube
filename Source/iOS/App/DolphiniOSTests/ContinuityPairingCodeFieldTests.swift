// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// The pairing code field keeps digits only, six at most, and calls six digits complete.
final class ContinuityPairingCodeFieldTests: XCTestCase {
  func testKeepsOnlyDigits() {
    XCTAssertEqual(ContinuityPairingCodeField.sanitized("12a3-4 5"), "12345")
  }

  func testCapsAtSixDigits() {
    XCTAssertEqual(ContinuityPairingCodeField.sanitized("12345678"), "123456")
  }

  func testAPastedSpacedCodeLandsWhole() {
    XCTAssertEqual(ContinuityPairingCodeField.sanitized("123 456"), "123456")
  }

  func testDropsNonASCIIDigits() {
    // Arabic-Indic digits pass `isNumber` but the host compares ASCII.
    XCTAssertEqual(ContinuityPairingCodeField.sanitized("١٢٣456"), "456")
  }

  func testCompleteness() {
    XCTAssertTrue(ContinuityPairingCodeField.isComplete("000000"))
    XCTAssertFalse(ContinuityPairingCodeField.isComplete("12345"))
    XCTAssertFalse(ContinuityPairingCodeField.isComplete("12345a"))
    XCTAssertFalse(ContinuityPairingCodeField.isComplete("1234567"))
  }
}
