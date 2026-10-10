// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class ConfigAdvancedModelBuilderTests: XCTestCase {
  private var changes: [ConfigAdvancedChange] = []
  private func model(_ state: ConfigAdvancedState = ConfigAdvancedState()) -> MenuModel {
    ConfigAdvancedModelBuilder.make(state: state) { self.changes.append($0) }
  }
  private func state(_ edit: (inout ConfigAdvancedState) -> Void) -> ConfigAdvancedState {
    var s = ConfigAdvancedState()
    edit(&s)
    return s
  }

  func test_rowOrder_andSections() {
    var ids = ["mem-override", "mem1", "mem2", "rtc-enabled"]
    #if !os(tvOS)
    ids.append("rtc-date")
    #endif
    XCTAssertEqual(model().allItems.map(\.id), ids)
    XCTAssertEqual(model().sections.map(\.header), ["Memory Override", "Custom RTC Options"])
    XCTAssertEqual(model().sections[0].footer, "For CPU and interpreter performance options, see Performance Tuning in Settings or Config.")
  }

  func test_everyRow_hasADescription() {
    for item in model().allItems { XCTAssertFalse((item.description ?? "").isEmpty, item.id) }
  }

  func test_everyToggleRow_emitsItsOwnChange() {
    let expected: [(String, (Bool) -> ConfigAdvancedChange)] = [
      ("mem-override", { .memOverride($0) }), ("rtc-enabled", { .rtcEnabled($0) }),
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

  func test_memorySteppers_haveTheirRanges_andEmitTheirOwnChange() {
    let m = model(state { $0.memOverride = true })
    let expected: [(String, ClosedRange<Double>, Double, ConfigAdvancedChange)] = [
      ("mem1", 24 ... 64, 30, .mem1MB(30)),
      ("mem2", 64 ... 128, 100, .mem2MB(100)),
    ]
    for (id, range, value, change) in expected {
      guard case .stepper(let stepper)? = m.item(id: id)?.role else { XCTFail("\(id) is not a stepper"); continue }
      XCTAssertEqual(stepper.range, range, id)
      changes = []
      stepper.value.wrappedValue = value
      XCTAssertEqual(changes, [change], id)
    }
  }

  func test_memorySteppers_showTheirMegabytes() {
    let m = model(state { $0.mem1MB = 48; $0.mem2MB = 96 })
    XCTAssertEqual(m.item(id: "mem1")?.currentValueTitle, "48 MB")
    XCTAssertEqual(m.item(id: "mem2")?.currentValueTitle, "96 MB")
  }

  func test_memorySteppers_disabledUntilTheOverrideIsOn() {
    XCTAssertEqual(model().item(id: "mem1")?.isEnabled, false)
    XCTAssertEqual(model().item(id: "mem2")?.isEnabled, false)
    XCTAssertEqual(model(state { $0.memOverride = true }).item(id: "mem2")?.isEnabled, true)
  }

  func test_rtcDefaultDate_is2000_01_01() {
    XCTAssertEqual(ConfigAdvancedState().rtcDate.timeIntervalSince1970, 946_684_800)
  }

  func test_rtcDateBinding_emitsTheDate() {
    let binding = ConfigAdvancedModelBuilder.rtcDateBinding(ConfigAdvancedState()) { self.changes.append($0) }
    let date = Date(timeIntervalSince1970: 1_000_000_000)
    binding.wrappedValue = date
    XCTAssertEqual(changes, [.rtcDate(date)])
  }

  #if !os(tvOS)
  func test_rtcDate_isACustomRow_disabledUntilRtcIsOn() {
    guard case .custom? = model().item(id: "rtc-date")?.role else { return XCTFail("custom") }
    XCTAssertEqual(model().item(id: "rtc-date")?.isEnabled, false)
    XCTAssertEqual(model(state { $0.rtcEnabled = true }).item(id: "rtc-date")?.isEnabled, true)
  }
  #endif
}
