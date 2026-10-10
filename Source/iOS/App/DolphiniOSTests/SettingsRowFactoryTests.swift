// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class SettingsRowFactoryTests: XCTestCase {
  func test_toggle_setReachesTheCallback_andDescriptionIsKept() {
    var received: [Bool] = []
    let item = SettingsRow.toggle("t", "Toggle", false, "Does a thing.") { received.append($0) }
    XCTAssertEqual(item.description, "Does a thing.")
    guard case .toggle(let binding) = item.role else { return XCTFail("toggle") }
    XCTAssertFalse(binding.wrappedValue)
    binding.wrappedValue = true
    XCTAssertEqual(received, [true])
  }

  func test_cycle_withIntValues_roundTripsThroughAnyHashable() {
    var received: [Int] = []
    let item = SettingsRow.cycle("c", "Cycle", [("Safe", 512), ("Default", 128)], 128, "d") { received.append($0) }
    XCTAssertEqual(item.currentValueTitle, "Default")
    guard case .cycle(_, let selection) = item.role else { return XCTFail("cycle") }
    selection.wrappedValue = AnyHashable(512)
    XCTAssertEqual(received, [512])
  }

  func test_cycle_withEnumValues_roundTrips() {
    var received: [GraphicsBackend] = []
    let item = SettingsRow.cycle("backend", "Backend", GraphicsBackend.allCases.map { ($0.label, $0) }, .metal, "d") { received.append($0) }
    XCTAssertEqual(item.currentValueTitle, GraphicsBackend.metal.label)
    guard case .cycle(_, let selection) = item.role else { return XCTFail("cycle") }
    selection.wrappedValue = AnyHashable(GraphicsBackend.vulkan)
    XCTAssertEqual(received, [.vulkan])
  }

  func test_cycle_aValueMatchingNoOption_showsADash() {
    let item = SettingsRow.cycle("c", "Cycle", [("A", 1), ("B", 2)], 99, "d") { _ in }
    XCTAssertEqual(item.currentValueTitle, "—", "spec §8: an unmatched value shows —, so builders must normalise first")
  }

  func test_cycle_ignoresAWrongTypedSelection() {
    var received: [Int] = []
    let item = SettingsRow.cycle("c", "Cycle", [("A", 1)], 1, "d") { received.append($0) }
    guard case .cycle(_, let selection) = item.role else { return XCTFail("cycle") }
    selection.wrappedValue = AnyHashable("not an int")
    XCTAssertTrue(received.isEmpty)
  }

  func test_stepper_formatsTheValue_andSetsThroughTheCallback() {
    var received: [Double] = []
    let item = SettingsRow.stepper("s", "Percent", 100, range: 1 ... 400, step: 1, format: { "\(Int($0))%" }, "d") { received.append($0) }
    XCTAssertEqual(item.currentValueTitle, "100%")
    guard case .stepper(let stepper) = item.role else { return XCTFail("stepper") }
    stepper.value.wrappedValue = 150
    XCTAssertEqual(received, [150])
  }

  func test_disabledAndBadge_areForwarded() {
    let item = SettingsRow.toggle("t", "T", true, "d", enabled: false, badge: "Auto") { _ in }
    XCTAssertFalse(item.isEnabled)
    XCTAssertEqual(item.badge, "Auto")
  }
}
