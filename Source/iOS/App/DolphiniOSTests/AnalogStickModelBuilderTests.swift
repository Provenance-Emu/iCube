// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class AnalogStickModelBuilderTests: XCTestCase {
  private var changes: [AnalogStickChange] = []
  private func model(_ state: AnalogStickState = AnalogStickState()) -> MenuModel {
    AnalogStickModelBuilder.make(state: state) { self.changes.append($0) }
  }

  func test_rowOrder_isOneHeaderlessSection() {
    XCTAssertEqual(model().sections.map(\.id), ["stick-feel"])
    XCTAssertEqual(model().sections.map(\.header), [nil])
    XCTAssertEqual(model().allItems.map(\.id), ["gain", "deadzone", "smoothing"])
    XCTAssertEqual(model().allItems.map(\.title), ["Analog Stick Gain", "Analog Stick Deadzone", "Analog Stick Smoothing"])
  }

  func test_everyRow_hasADescription() {
    for item in model().allItems { XCTAssertFalse((item.description ?? "").isEmpty, item.id) }
  }

  func test_steppers_haveTheirRanges_andEmitTheirOwnChange() {
    let table: [(String, ClosedRange<Double>, Double, Double, AnalogStickChange)] = [
      ("gain", 0.1...3.0, 0.05, 2.0, .gain(2.0)),
      ("deadzone", 0.0...0.49, 0.01, 0.2, .deadzone(0.2)),
      ("smoothing", 0.0...0.9, 0.05, 0.5, .smoothing(0.5)),
    ]
    let m = model()
    for (id, range, step, value, change) in table {
      guard case .stepper(let stepper)? = m.item(id: id)?.role else { XCTFail("\(id) is not a stepper"); continue }
      XCTAssertEqual(stepper.range, range, id)
      XCTAssertEqual(stepper.step, step, id)
      changes = []
      stepper.value.wrappedValue = value
      XCTAssertEqual(changes, [change], id)
    }
  }

  func test_steppers_reflectTheSnapshot_andFormatTwoDecimals() {
    var s = AnalogStickState()
    s.gain = 1.5
    s.deadzone = 0.1
    s.smoothing = 0.25
    let m = model(s)
    let table: [(String, Double, String)] = [("gain", 1.5, "1.50"), ("deadzone", 0.1, "0.10"), ("smoothing", 0.25, "0.25")]
    for (id, value, text) in table {
      guard case .stepper(let stepper)? = m.item(id: id)?.role else { XCTFail("\(id) is not a stepper"); continue }
      XCTAssertEqual(stepper.value.wrappedValue, value, id)
      XCTAssertEqual(stepper.format(value), text, id)
    }
    XCTAssertEqual(AnalogStickModelBuilder.format(1.0), "1.00")
  }

  func test_stored_usesTheStoredDouble_elseTheDefault() {
    let table: [(Any?, Double, Double)] = [
      (nil, 1.0, 1.0), (0.0, 1.0, 0.0), (2.5, 1.0, 2.5), ("junk", 0.05, 0.05),
    ]
    for (object, fallback, expected) in table {
      XCTAssertEqual(AnalogStickState.stored(object, default: fallback), expected, "\(String(describing: object))")
    }
  }

  func test_defaults_matchTheOldView() {
    let s = AnalogStickState()
    XCTAssertEqual(s.gain, 1.0)
    XCTAssertEqual(s.deadzone, 0.05)
    XCTAssertEqual(s.smoothing, 0.0)
  }

  func test_keys_areTheOldDsuKeys() {
    XCTAssertEqual(AnalogStickKey.gain, "dsu_gyro_gain")
    XCTAssertEqual(AnalogStickKey.deadzone, "dsu_deadzone")
    XCTAssertEqual(AnalogStickKey.smoothing, "dsu_smoothing")
  }
}
