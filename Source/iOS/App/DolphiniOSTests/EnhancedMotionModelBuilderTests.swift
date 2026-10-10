// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class EnhancedMotionModelBuilderTests: XCTestCase {
  private var changes: [EnhancedMotionChange] = []
  private func model(_ state: EnhancedMotionState = EnhancedMotionState()) -> MenuModel {
    EnhancedMotionModelBuilder.make(state: state) { self.changes.append($0) }
  }
  private func state(_ edit: (inout EnhancedMotionState) -> Void) -> EnhancedMotionState {
    var s = EnhancedMotionState()
    edit(&s)
    return s
  }

  func test_rowOrder_with6DOFOn() {
    XCTAssertEqual(model().allItems.map(\.id), ["horizontal-movement", "wiimote-imu", "six-dof", "nunchuk-imu", "recommended"])
    XCTAssertEqual(model().sections.map(\.id), ["gyro-pointer", "full-motion", "quick-setup"])
    XCTAssertEqual(model().sections.map(\.header), ["Gyro Pointer", "Full Motion Mapping", "Quick Setup"])
  }

  func test_nunchukRow_isHiddenWhile6DOFIsOff() {
    let m = model(state { $0.full6DOF = false })
    XCTAssertEqual(m.allItems.map(\.id), ["horizontal-movement", "wiimote-imu", "six-dof", "recommended"])
    XCTAssertNil(m.item(id: "nunchuk-imu"))
  }

  func test_defaultState_containsTheNunchukRow() {
    XCTAssertNotNil(model().item(id: "nunchuk-imu"))
    XCTAssertEqual(EnhancedMotionState(), state { $0.horizontalMotionMode = .roll; $0.wiimoteIMU = true; $0.full6DOF = true; $0.nunchukIMU = false })
  }

  func test_everyRow_hasADescription() {
    for on in [true, false] {
      for item in model(state { $0.full6DOF = on }).allItems { XCTAssertFalse((item.description ?? "").isEmpty, item.id) }
    }
  }

  func test_everyToggleRow_emitsItsOwnChange_bothWays() {
    let expected: [(String, (Bool) -> EnhancedMotionChange)] = [
      ("wiimote-imu", { .wiimoteIMU($0) }), ("six-dof", { .full6DOF($0) }), ("nunchuk-imu", { .nunchukIMU($0) }),
    ]
    let m = model()
    for (id, change) in expected {
      guard case .toggle(let binding)? = m.item(id: id)?.role else { XCTFail("\(id) is not a toggle"); continue }
      for value in [true, false] {
        changes = []
        binding.wrappedValue = value
        XCTAssertEqual(changes, [change(value)], id)
      }
    }
  }

  func test_toggles_reflectTheSnapshot() {
    let m = model(state { $0.wiimoteIMU = false; $0.full6DOF = true; $0.nunchukIMU = true })
    for (id, expected) in [("wiimote-imu", false), ("six-dof", true), ("nunchuk-imu", true)] {
      guard case .toggle(let binding)? = m.item(id: id)?.role else { XCTFail("\(id) is not a toggle"); continue }
      XCTAssertEqual(binding.wrappedValue, expected, id)
    }
  }

  func test_horizontalMovement_listsBothModes_andEmitsTheChoice() {
    guard case .cycle(let options, let selection)? = model().item(id: "horizontal-movement")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), HorizontalMotionMode.allCases.map(\.label))
    XCTAssertEqual(options.map(\.1), HorizontalMotionMode.allCases.map { AnyHashable($0) })
    XCTAssertEqual(selection.wrappedValue, AnyHashable(HorizontalMotionMode.roll))
    selection.wrappedValue = AnyHashable(HorizontalMotionMode.yaw)
    XCTAssertEqual(changes, [.horizontalMotion(.yaw)])
  }

  func test_horizontalMovement_selectionFollowsTheSnapshot() {
    guard case .cycle(_, let selection)? = model(state { $0.horizontalMotionMode = .yaw }).item(id: "horizontal-movement")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(selection.wrappedValue, AnyHashable(HorizontalMotionMode.yaw))
  }

  func test_horizontalMovement_descriptionAppendsTheSelectedModesText() {
    for mode in HorizontalMotionMode.allCases {
      let description = model(state { $0.horizontalMotionMode = mode }).item(id: "horizontal-movement")?.description ?? ""
      XCTAssertTrue(description.contains(mode.description), "\(mode)")
      for other in HorizontalMotionMode.allCases where other != mode {
        XCTAssertFalse(description.contains(other.description), "\(mode) shows \(other)")
      }
    }
  }

  func test_recommended_isAnAction_emittingApplyRecommended() {
    guard case .action(let run)? = model().item(id: "recommended")?.role else { return XCTFail("action") }
    run()
    XCTAssertEqual(changes, [.applyRecommended])
  }
}
