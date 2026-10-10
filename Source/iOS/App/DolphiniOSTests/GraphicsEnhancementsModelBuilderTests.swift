// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class GraphicsEnhancementsModelBuilderTests: XCTestCase {
  private var changes: [GraphicsEnhancementsChange] = []
  private func model(_ state: GraphicsEnhancementsState = GraphicsEnhancementsState()) -> MenuModel {
    GraphicsEnhancementsModelBuilder.make(state: state) { self.changes.append($0) }
  }
  private func state(_ edit: (inout GraphicsEnhancementsState) -> Void) -> GraphicsEnhancementsState {
    var s = GraphicsEnhancementsState()
    edit(&s)
    return s
  }

  private let baseRows = [
    "efb-scale", "anisotropy", "msaa", "ssaa", "output-resampling", "true-color", "disable-copy-filter",
    "widescreen-hack", "hdr-output", "gpu-texture-decoding", "disable-fog", "arbitrary-mipmap",
  ]

  func test_rowOrder_matchesTheOldScreen() {
    XCTAssertEqual(model().allItems.map(\.id), baseRows)
    XCTAssertEqual(model().sections.map(\.header), ["Internal Resolution", "Texture Filtering", "Enhancements", "Compatibility"])
  }

  func test_thresholdRow_appearsAfterDetection() {
    let m = model(state { $0.arbitraryMipmapDetection = true })
    XCTAssertEqual(m.allItems.count, 13)
    XCTAssertEqual(m.allItems.suffix(2).map(\.id), ["arbitrary-mipmap", "arbitrary-mipmap-threshold"])
  }

  func test_everyRow_hasADescription() {
    for item in model(state { $0.arbitraryMipmapDetection = true }).allItems {
      XCTAssertFalse((item.description ?? "").isEmpty, item.id)
    }
  }

  func test_efbScale_disabledAndBadgedGame_whenTheGameOverridesIt() {
    let item = model(state { $0.efbOverride = .game }).item(id: "efb-scale")
    XCTAssertEqual(item?.isEnabled, false)
    XCTAssertEqual(item?.badge, L("Game"))
  }

  func test_efbScale_disabledAndBadgedAuto_whenAutoIRDrivesIt() {
    let item = model(state { $0.efbOverride = .auto }).item(id: "efb-scale")
    XCTAssertEqual(item?.isEnabled, false)
    XCTAssertEqual(item?.badge, L("Auto"))
  }

  func test_efbScale_enabledAndUnbadged_whenNothingOverridesIt() {
    let item = model(state { $0.efbOverride = .none }).item(id: "efb-scale")
    XCTAssertEqual(item?.isEnabled, true)
    XCTAssertNil(item?.badge)
  }

  func test_efbScale_options_followEfbMaxScale() {
    guard case .cycle(let options, _)? = model(state { $0.efbMaxScale = 4 }).item(id: "efb-scale")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map { $0.0 }, ["Auto (fit window)", "1x (Native)", "2x", "3x", "4x"])
    XCTAssertEqual(options.map { $0.1 }, [0, 1, 2, 3, 4].map { AnyHashable($0) })
  }

  func test_efbScale_options_atMaxScaleOne_areAutoAndNativeOnly() {
    guard case .cycle(let options, _)? = model(state { $0.efbMaxScale = 1 }).item(id: "efb-scale")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map { $0.0 }, ["Auto (fit window)", "1x (Native)"])
  }

  func test_cycleOptions_useTheConfigValues() {
    guard case .cycle(let aniso, _)? = model().item(id: "anisotropy")?.role,
          case .cycle(let msaa, _)? = model().item(id: "msaa")?.role,
          case .cycle(let resampling, _)? = model().item(id: "output-resampling")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(aniso.map { $0.0 }, ["1x", "2x", "4x", "8x", "16x"])
    XCTAssertEqual(aniso.map { $0.1 }, [1, 2, 4, 8, 16].map { AnyHashable($0) })
    XCTAssertEqual(msaa.map { $0.0 }, ["None", "2x", "4x", "8x"])
    XCTAssertEqual(msaa.map { $0.1 }, [1, 2, 4, 8].map { AnyHashable($0) })
    XCTAssertEqual(resampling.map { $0.0 }, ["Default", "Bilinear", "B-Spline", "Mitchell-Netravali", "Catmull-Rom", "Sharp Bilinear", "Area Sampling"])
    XCTAssertEqual(resampling.map { $0.1 }, (0 ... 6).map { AnyHashable($0) })
  }

  func test_msaaTitle_containsMSAA() {
    XCTAssertEqual(model().item(id: "msaa")?.title, "Anti-Aliasing (MSAA)")
  }

  func test_ssaa_disabledWhileMsaaIsNone_andItsDescriptionSwitches() {
    let off = model(state { $0.msaa = 1 }).item(id: "ssaa")
    XCTAssertEqual(off?.isEnabled, false)
    XCTAssertEqual(off?.description, "Enable MSAA (above None) first to use supersampling.")
    let on = model(state { $0.msaa = 4 }).item(id: "ssaa")
    XCTAssertEqual(on?.isEnabled, true)
    XCTAssertTrue(on!.description!.hasPrefix("Supersampling renders MSAA samples"))
  }

  func test_thresholdRow_isAStepperWithTheOldRangeAndFormat() {
    let item = model(state { $0.arbitraryMipmapDetection = true }).item(id: "arbitrary-mipmap-threshold")
    guard case .stepper(let stepper)? = item?.role else { return XCTFail("stepper") }
    XCTAssertEqual(stepper.range, 0 ... 30)
    XCTAssertEqual(stepper.step, 0.1)
    XCTAssertEqual(item?.currentValueTitle, "0.50")
    stepper.value.wrappedValue = 3.25
    XCTAssertEqual(changes, [.arbitraryMipmapThreshold(3.25)])
  }

  func test_msaaLadder_normalisesStoredSampleCounts() {
    for (stored, shown) in [(0, 1), (1, 1), (2, 2), (3, 2), (4, 4), (5, 4), (7, 4), (8, 8), (16, 8)] {
      XCTAssertEqual(GraphicsEnhancementsState.normalizedMsaa(stored), shown, "stored \(stored)")
    }
  }

  func test_anisotropyLadder_snapsToTheStepBelow() {
    for (stored, shown) in [(-1, 1), (0, 1), (1, 1), (3, 2), (4, 4), (15, 8), (16, 16), (32, 16)] {
      XCTAssertEqual(GraphicsEnhancementsState.normalizedAnisotropy(stored), shown, "stored \(stored)")
    }
  }

  /// Every toggle row emits its OWN change with the value written; a mapping slip in any closure fails here.
  func test_everyToggleRow_emitsItsOwnChange() {
    let expected: [(String, (Bool) -> GraphicsEnhancementsChange)] = [
      ("ssaa", { .ssaa($0) }), ("true-color", { .trueColor($0) }), ("disable-copy-filter", { .disableCopyFilter($0) }),
      ("widescreen-hack", { .widescreenHack($0) }), ("hdr-output", { .hdrOutput($0) }),
      ("gpu-texture-decoding", { .gpuTextureDecoding($0) }), ("disable-fog", { .disableFog($0) }),
      ("arbitrary-mipmap", { .arbitraryMipmapDetection($0) }),
    ]
    let m = model()
    for (id, change) in expected {
      guard case .toggle(let binding)? = m.item(id: id)?.role else { XCTFail("\(id) is not a toggle"); continue }
      changes = []
      binding.wrappedValue = true
      XCTAssertEqual(changes, [change(true)], id)
      changes = []
      binding.wrappedValue = false
      XCTAssertEqual(changes, [change(false)], id)
    }
  }

  func test_everyCycleRow_emitsItsOwnChange() {
    let expected: [(String, Int, GraphicsEnhancementsChange)] = [
      ("efb-scale", 3, .efbScale(3)), ("anisotropy", 16, .anisotropy(16)), ("msaa", 8, .msaa(8)), ("output-resampling", 6, .outputResampling(6)),
    ]
    let m = model()
    for (id, value, change) in expected {
      guard case .cycle(_, let selection)? = m.item(id: id)?.role else { XCTFail("\(id) is not a cycle"); continue }
      changes = []
      selection.wrappedValue = AnyHashable(value)
      XCTAssertEqual(changes, [change], id)
    }
  }

  // MARK: Side effects

  private func effects(_ change: GraphicsEnhancementsChange, ssaa: Bool = false) -> [GraphicsEnhancementsSideEffect] {
    GraphicsEnhancementsState.sideEffects(of: change, in: state { $0.ssaa = ssaa })
  }

  func test_sideEffects_autoScaleLeavesAutoIRAlone() {
    XCTAssertEqual(effects(.efbScale(0)), [])
  }

  func test_sideEffects_aFixedScaleTurnsAutoIROff() {
    XCTAssertEqual(effects(.efbScale(1)), [.autoIROff])
    XCTAssertEqual(effects(.efbScale(4)), [.autoIROff])
  }

  func test_sideEffects_msaaToNoneClearsSSAAOnlyWhenItIsOn() {
    XCTAssertEqual(effects(.msaa(1), ssaa: true), [.clearSSAA])
    XCTAssertEqual(effects(.msaa(1), ssaa: false), [])
    XCTAssertEqual(effects(.msaa(2), ssaa: true), [])
  }

  func test_sideEffects_otherChangesHaveNone() {
    XCTAssertEqual(effects(.ssaa(true)), [])
    XCTAssertEqual(effects(.anisotropy(1), ssaa: true), [])
    XCTAssertEqual(effects(.arbitraryMipmapThreshold(1)), [])
  }

  func test_sideEffects_theTwoRulesAreIndependent() {
    XCTAssertFalse(effects(.efbScale(2), ssaa: true).contains(.clearSSAA), "a scale pick does not clear SSAA")
    XCTAssertFalse(effects(.msaa(1), ssaa: true).contains(.autoIROff), "MSAA does not touch Auto-IR")
  }
}
