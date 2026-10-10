// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class ConfigGeneralModelBuilderTests: XCTestCase {
  private var changes: [ConfigGeneralChange] = []
  private func model(_ state: ConfigGeneralState = ConfigGeneralState()) -> MenuModel {
    ConfigGeneralModelBuilder.make(state: state) { self.changes.append($0) }
  }
  private func state(_ edit: (inout ConfigGeneralState) -> Void) -> ConfigGeneralState {
    var s = ConfigGeneralState()
    edit(&s)
    return s
  }
  private func labels(_ id: String, _ m: MenuModel) -> [String] {
    guard case .cycle(let options, _)? = m.item(id: id)?.role else { return [] }
    return options.map(\.0)
  }
  private func values(_ id: String, _ m: MenuModel) -> [Int] {
    guard case .cycle(let options, _)? = m.item(id: id)?.role else { return [] }
    return options.compactMap { $0.1.base as? Int }
  }

  func test_rowOrder_andSections() {
    XCTAssertEqual(model().allItems.map(\.id), [
      "dual-core", "dsp-thread", "cheats", "override-region", "auto-disc-change", "fast-disc-speed", "resume-where-left-off",
      "speed-limit", "fast-forward-speed", "fallback-region",
    ])
    XCTAssertEqual(model().sections.map(\.header), ["Basic Settings", "Speed", nil])
  }

  func test_everyRow_hasADescription() {
    for item in model().allItems { XCTAssertFalse((item.description ?? "").isEmpty, item.id) }
  }

  func test_pickerHelp_isFoldedIntoTheDescriptions_withoutMarkup() {
    let m = model()
    XCTAssertTrue(m.item(id: "speed-limit")?.description?.hasSuffix("If unsure, select 100%.") == true)
    XCTAssertTrue(m.item(id: "fast-forward-speed")?.description?.hasSuffix("300% (3x) is recommended for most games.") == true)
    XCTAssertTrue(m.item(id: "fallback-region")?.description?.hasSuffix("This setting cannot be changed while emulation is active.") == true)
    for item in m.allItems { XCTAssertFalse((item.description ?? "").contains("<"), item.id) }
  }

  func test_everyToggleRow_emitsItsOwnChange() {
    let expected: [(String, (Bool) -> ConfigGeneralChange)] = [
      ("dual-core", { .dualCore($0) }), ("dsp-thread", { .dspThread($0) }), ("cheats", { .cheats($0) }),
      ("override-region", { .overrideRegion($0) }), ("auto-disc-change", { .autoDiscChange($0) }),
      ("fast-disc-speed", { .fastDiscSpeed($0) }), ("resume-where-left-off", { .resumeWhereLeftOff($0) }),
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

  func test_everyCycleRow_emitsItsOwnChange() {
    let expected: [(String, AnyHashable, ConfigGeneralChange)] = [
      ("speed-limit", AnyHashable(150), .speedLimit(150)),
      ("fast-forward-speed", AnyHashable(400), .fastForwardSpeed(400)),
      ("fallback-region", AnyHashable(Region.pal), .fallbackRegion(.pal)),
    ]
    let m = model()
    for (id, value, change) in expected {
      guard case .cycle(_, let selection)? = m.item(id: id)?.role else { XCTFail("\(id) is not a cycle"); continue }
      changes = []
      selection.wrappedValue = value
      XCTAssertEqual(changes, [change], id)
    }
  }

  func test_toggleRows_showTheStateValue() {
    let m = model(state { $0.dualCore = true; $0.cheats = true; $0.resumeWhereLeftOff = true })
    for id in ["dual-core", "cheats", "resume-where-left-off"] { XCTAssertEqual(m.item(id: id)?.currentValueTitle, "On", id) }
    for id in ["dsp-thread", "override-region", "auto-disc-change", "fast-disc-speed"] { XCTAssertEqual(m.item(id: id)?.currentValueTitle, "Off", id) }
  }

  func test_speedRowsCarryTheirIcons() {
    XCTAssertEqual(model().item(id: "speed-limit")?.icon, "speedometer")
    XCTAssertEqual(model().item(id: "fast-forward-speed")?.icon, "forward.fill")
  }

  func test_fallbackRegionCycle_excludesTheErrorCase() {
    XCTAssertEqual(labels("fallback-region", model()), ["NTSC-J", "NTSC-U", "PAL", "NTSC-K"])
  }

  func test_speedLimitLabels() {
    XCTAssertEqual(ConfigGeneralState.speedLimitLabel(0), "Unlimited")
    XCTAssertEqual(ConfigGeneralState.speedLimitLabel(100), "100% (Normal Speed)")
    XCTAssertEqual(ConfigGeneralState.speedLimitLabel(150), "150%")
  }

  func test_speedLimitOptions_startWithUnlimited_andCover10to200() {
    let vals = values("speed-limit", model())
    XCTAssertEqual(vals.first, 0)
    XCTAssertEqual(Array(vals.dropFirst()), Array(stride(from: 10, through: 200, by: 10)))
    XCTAssertEqual(labels("speed-limit", model()).first, "Unlimited")
  }

  func test_fastForwardOptions_andLabels() {
    XCTAssertEqual(values("fast-forward-speed", model()), [0, 200, 300, 400, 500, 600, 800, 1000])
    XCTAssertEqual(ConfigGeneralState.fastForwardLabel(0), "Unlimited")
    XCTAssertEqual(ConfigGeneralState.fastForwardLabel(200), "200% (2x)")
    XCTAssertEqual(ConfigGeneralState.fastForwardLabel(1000), "1000% (10x)")
  }

  func test_offLadderSpeed_isInsertedInOrder_soTheRowNeverShowsADash() {
    let speed = model(state { $0.speedLimitPercent = 125 })
    let speedValues = values("speed-limit", speed)
    XCTAssertEqual(speedValues.first, 0)
    XCTAssertEqual(speedValues.firstIndex(of: 125), speedValues.firstIndex(of: 120)! + 1)
    XCTAssertEqual(speedValues.firstIndex(of: 130), speedValues.firstIndex(of: 125)! + 1)
    XCTAssertEqual(speed.item(id: "speed-limit")?.currentValueTitle, "125%")

    let fast = model(state { $0.fastForwardSpeedPercent = 250 })
    let fastValues = values("fast-forward-speed", fast)
    XCTAssertEqual(fastValues, [0, 200, 250, 300, 400, 500, 600, 800, 1000])
    XCTAssertEqual(fast.item(id: "fast-forward-speed")?.currentValueTitle, "250%")
  }

  func test_onLadderSpeed_addsNoOption() {
    XCTAssertEqual(values("speed-limit", model(state { $0.speedLimitPercent = 100 })).count, 21)
    XCTAssertEqual(values("fast-forward-speed", model(state { $0.fastForwardSpeedPercent = 0 })).count, 8)
  }

  func test_fastForwardUnset_is300_butStoredZeroIsUnlimited() {
    XCTAssertEqual(ConfigGeneralState.storedFastForward(nil), 300)
    XCTAssertEqual(ConfigGeneralState.storedFastForward(0), 0)
    XCTAssertEqual(ConfigGeneralState.storedFastForward(400), 400)
    XCTAssertEqual(ConfigGeneralState().fastForwardSpeedPercent, 300)
  }

  func test_displayedRegion_showsNTSCU_forAnUnknownStoredValue() {
    for raw in [3, 5, -1, 99] { XCTAssertEqual(ConfigGeneralState.displayedRegion(raw: raw), .ntscU, "\(raw)") }
    XCTAssertEqual(ConfigGeneralState.displayedRegion(raw: 2), .pal)
    XCTAssertEqual(model(state { $0.fallbackRegion = .ntscK }).item(id: "fallback-region")?.currentValueTitle, "NTSC-K")
  }

  func test_fallbackRegionSeed_onlyForAnUnknownRegion() {
    for raw in [3, 5, -1, 99] { XCTAssertEqual(ConfigGeneralState.fallbackRegionSeed(configRaw: raw), .ntscU, "\(raw)") }
    for raw in [0, 1, 2, 4] { XCTAssertNil(ConfigGeneralState.fallbackRegionSeed(configRaw: raw), "\(raw)") }
  }

  func test_defaultsKeys_arePinned() {
    XCTAssertEqual(ConfigGeneralDefaultsKey.fastForwardSpeedPercent, "fast_forward_speed_percent")
    XCTAssertEqual(ConfigGeneralDefaultsKey.resumeWhereLeftOff, "resume_where_left_off")
  }
}
