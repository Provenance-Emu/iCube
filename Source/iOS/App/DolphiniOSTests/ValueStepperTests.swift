// DolphiniOSTests/ValueStepperTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class ValueStepperTests: XCTestCase {
  private func stepper(range: ClosedRange<Double>, step: Double) -> MenuStepper {
    MenuStepper(value: .constant(range.lowerBound), range: range, step: step, format: { "\($0)" })
  }

  func test_stepped_clampsAtBothEnds() {
    let s = stepper(range: 0 ... 400, step: 5)
    XCTAssertEqual(s.stepped(100, by: 1), 105)
    XCTAssertEqual(s.stepped(398, by: 1), 400, "clamped at the top")
    XCTAssertEqual(s.stepped(3, by: -1), 0, "clamped at the bottom")
  }

  func test_stepped_tenthsDoNotDriftOffTheGrid() {
    let s = stepper(range: 0 ... 30, step: 0.1)
    var value = 0.0
    for _ in 0 ..< 3 { value = s.stepped(value, by: 1) }
    XCTAssertEqual(value, 0.3, "0.1 + 0.1 + 0.1 is 0.30000000000000004 without snapping")
    for _ in 0 ..< 7 { value = s.stepped(value, by: 1) }
    XCTAssertEqual(value, 1.0)
  }

  func test_stepped_snapsAnOffGridStartToTheGrid() {
    let s = stepper(range: 0 ... 30, step: 0.1)
    XCTAssertEqual(s.stepped(0.34, by: 1), 0.4)
    XCTAssertEqual(s.stepped(0.34, by: -1), 0.2)
  }

  func test_stepped_integerStepsStayIntegral() {
    let s = stepper(range: 1 ... 400, step: 1)
    XCTAssertEqual(s.stepped(37, by: 1), 38)
    XCTAssertEqual(s.stepped(37.0000001, by: -1), 36)
  }
}
