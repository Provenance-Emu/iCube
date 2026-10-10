// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class PerformanceTuningModelBuilderTests: XCTestCase {
  private var changes: [PerformanceTuningChange] = []
  private func model(_ state: PerformanceTuningState, showValidation: Bool = false) -> MenuModel {
    PerformanceTuningModelBuilder.make(state: state, showValidation: showValidation) { self.changes.append($0) }
  }
  private func state(_ edit: (inout PerformanceTuningState) -> Void) -> PerformanceTuningState {
    var s = PerformanceTuningState()
    edit(&s)
    return s
  }
  private var cir: PerformanceTuningState { state { $0.jitAvailable = true; $0.engine = .cachedInterpreter } }
  private var ir: PerformanceTuningState { state { $0.jitAvailable = true; $0.engine = .cachedInterpreterIR } }
  private var jit: PerformanceTuningState { state { $0.jitAvailable = true; $0.engine = .jitARM64 } }

  private func isOn(_ item: MenuItem?) -> Bool? {
    guard case .toggle(let binding)? = item?.role else { return nil }
    return binding.wrappedValue
  }

  // MARK: Structure

  func test_sections_inOrder_forACachedInterpreter() {
    XCTAssertEqual(model(cir).sections.map(\.id),
                   ["cpu-options", "engine-optimizations", "validation", "diagnostics", "clock-override", "vbi-override"])
  }

  func test_engineOptimizations_absent_andFallbackShown_forTheJITEngine() {
    let m = model(jit)
    XCTAssertEqual(m.sections.map(\.id), ["cpu-options", "engine-optimizations-hint", "clock-override", "vbi-override"])
    XCTAssertNil(m.sections.first { $0.id == "engine-optimizations" })
    XCTAssertNil(m.sections.first { $0.id == "validation" })
    XCTAssertNil(m.sections.first { $0.id == "diagnostics" })
    let hint = m.item(id: "engine-optimizations-hint")
    XCTAssertEqual(hint?.isEnabled, false)
    XCTAssertEqual(hint?.title, "Select a Cached Interpreter engine")
    XCTAssertEqual(m.section(containing: "engine-optimizations-hint")?.header, "Engine Optimizations")
    XCTAssertNil(model(cir).item(id: "engine-optimizations-hint"))
  }

  func test_plainInterpreter_showsTheFallbackToo() {
    let m = model(state { $0.jitAvailable = true; $0.engine = .interpreter })
    XCTAssertNotNil(m.item(id: "engine-optimizations-hint"))
    XCTAssertNil(m.item(id: "reset-optimizations"))
  }

  func test_irEngine_showsIRRows_notCIRRows_andNoDiagnostics() {
    let ids = model(ir, showValidation: true).allItems.map(\.id)
    XCTAssertTrue(ids.contains("ir-constant-address-fusion"))
    XCTAssertTrue(ids.contains("ir-micro-op-fusion"))
    XCTAssertTrue(ids.contains("ir-validate-pic-load-store"))
    XCTAssertFalse(ids.contains { $0.hasPrefix("cir-") })
    XCTAssertEqual(model(ir).sections.map(\.id), ["cpu-options", "engine-optimizations", "validation", "clock-override", "vbi-override"])
  }

  func test_cachedInterpreter_showsCIRRows_notIRRows() {
    let ids = model(cir, showValidation: true).allItems.map(\.id)
    XCTAssertTrue(ids.contains("cir-micro-op-fusion"))
    XCTAssertTrue(ids.contains("cir-validate-specialized-ops"))
    XCTAssertTrue(ids.contains("cir-profiler"))
    XCTAssertFalse(ids.contains { $0.hasPrefix("ir-") })
  }

  func test_footers_followTheEngineAndJIT() {
    XCTAssertTrue(model(cir).sections[1].footer!.hasPrefix("Optimizations for the Cached Interpreter engine."))
    XCTAssertTrue(model(ir).sections[1].footer!.hasPrefix("Optimizations for the Cached Interpreter (IR) engine."))
    XCTAssertTrue(model(cir).sections[0].footer!.hasPrefix("These options control"))
    XCTAssertTrue(model(state { $0.engine = .cachedInterpreter }).sections[0].footer!.hasPrefix("This build runs without JIT"))
  }

  func test_performanceAB_isADestination_andResetIsAnAction() {
    let m = model(cir)
    guard case .destination? = m.item(id: "performance-ab")?.role else { return XCTFail("destination") }
    XCTAssertEqual(m.item(id: "performance-ab")?.title, "Performance A/B & Snapshots")
    XCTAssertEqual(m.item(id: "performance-ab")?.showsChevron, true)
    XCTAssertEqual(m.sections[1].items.prefix(2).map(\.id), ["performance-ab", "reset-optimizations"])
  }

  func test_recommendedRows_carryTheBadge_andKeepTheirDescription() {
    let m = model(cir)
    for id in ["pic-load-store", "specialized-ops", "block-linking", "dynamic-links", "neon-paired-single-math", "cir-micro-op-fusion"] {
      XCTAssertEqual(m.item(id: id)?.badge, "Recommended", id)
      XCTAssertFalse((m.item(id: id)?.description ?? "").isEmpty, id)
    }
    XCTAssertNil(m.item(id: "cir-dead-flag-elimination")?.badge)
    XCTAssertNil(model(ir).item(id: "ir-micro-op-fusion")?.badge)
  }

  // MARK: Engine cycle

  func test_engineCycle_showsCachedInterpreter_whenJITIsUnavailable() {
    let m = model(state { $0.jitAvailable = false; $0.engine = .jitARM64 })
    XCTAssertEqual(m.item(id: "cpu-engine")?.currentValueTitle, CpuEngine.cachedInterpreter.label)
    guard case .cycle(let options, _)? = m.item(id: "cpu-engine")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map { $0.1 }, [CpuEngine.interpreter, .cachedInterpreter, .cachedInterpreterIR].map { AnyHashable($0) })
    // A stored JIT core on a jitless build also gets the Cached Interpreter optimisations, as it does at runtime.
    XCTAssertNotNil(m.item(id: "pic-load-store"))
  }

  func test_engineCycle_offersEveryEngine_whenJITIsAvailable() {
    guard case .cycle(let options, let selection)? = model(jit).item(id: "cpu-engine")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map { $0.0 }, CpuEngine.allCases.map(\.label))
    XCTAssertEqual(model(jit).item(id: "cpu-engine")?.currentValueTitle, CpuEngine.jitARM64.label)
    selection.wrappedValue = AnyHashable(CpuEngine.cachedInterpreterIR)
    XCTAssertEqual(changes, [.cpuEngine(.cachedInterpreterIR)])
  }

  func test_effectiveEngine_mapsJITOnlyWhenJitless() {
    XCTAssertEqual(state { $0.jitAvailable = false; $0.engine = .jit64 }.effectiveEngine, .cachedInterpreter)
    XCTAssertEqual(state { $0.jitAvailable = true; $0.engine = .jit64 }.effectiveEngine, .jit64)
    XCTAssertEqual(state { $0.jitAvailable = false; $0.engine = .interpreter }.effectiveEngine, .interpreter)
    XCTAssertEqual(state { $0.jitAvailable = false; $0.engine = .cachedInterpreterIR }.effectiveEngine, .cachedInterpreterIR)
  }

  // MARK: Vertex loader

  func test_vertexLoaderDefault_isNEON() {
    XCTAssertEqual(PerformanceTuningState().vertexLoaderMode, 1)
    XCTAssertEqual(model(cir).item(id: "vertex-loader")?.currentValueTitle, "NEON SIMD (default)")
    guard case .cycle(let options, let selection)? = model(cir).item(id: "vertex-loader")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map { $0.0 }, ["Software", "NEON SIMD (default)", "Compare (validate)"])
    XCTAssertEqual(options.map { $0.1 }, [0, 1, 2].map { AnyHashable($0) })
    selection.wrappedValue = AnyHashable(2)
    XCTAssertEqual(changes, [.vertexLoaderMode(2)])
  }

  func test_vertexLoaderStoredValue_unsetIsNEON_storedWins() {
    XCTAssertEqual(VertexLoaderMode.storedRawValue(nil), 1)
    XCTAssertEqual(VertexLoaderMode.storedRawValue(0), 0)
    XCTAssertEqual(VertexLoaderMode.storedRawValue(2), 2)
  }

  // MARK: Clock overrides

  func test_cpuClockPercent_isAStepper_1to400() {
    let item = model(state { $0.cpuClockEnabled = true; $0.cpuClockPercent = 150 }).item(id: "cpu-clock-percent")
    guard case .stepper(let stepper)? = item?.role else { return XCTFail("stepper") }
    XCTAssertEqual(stepper.range, 1 ... 400)
    XCTAssertEqual(stepper.step, 1)
    XCTAssertEqual(item?.currentValueTitle, "150%")
    stepper.value.wrappedValue = 175
    XCTAssertEqual(changes, [.cpuClockPercent(175)])
    XCTAssertEqual(item?.isEnabled, true)
    XCTAssertNil(item?.badge)
  }

  func test_vbiPercent_isAStepper_andEmitsItsOwnChange() {
    let item = model(state { $0.vbiEnabled = true }).item(id: "vbi-percent")
    guard case .stepper(let stepper)? = item?.role else { return XCTFail("stepper") }
    XCTAssertEqual(stepper.range, 1 ... 400)
    stepper.value.wrappedValue = 60
    XCTAssertEqual(changes, [.vbiPercent(60)])
  }

  func test_clockPercent_disabledUntilTheOverrideIsEnabled() {
    XCTAssertEqual(model(state { $0.cpuClockEnabled = false }).item(id: "cpu-clock-percent")?.isEnabled, false)
    XCTAssertEqual(model(state { $0.vbiEnabled = false }).item(id: "vbi-percent")?.isEnabled, false)
  }

  func test_cpuClockPercent_disabledAndBadgedAuto_whenAdaptiveClockDrivesIt() {
    let m = model(state { $0.cpuClockEnabled = true; $0.cpuClockOverride = .auto })
    XCTAssertEqual(m.item(id: "cpu-clock-enabled")?.isEnabled, false)
    XCTAssertEqual(m.item(id: "cpu-clock-percent")?.isEnabled, false)
    XCTAssertEqual(m.item(id: "cpu-clock-percent")?.badge, L("Auto"))
    XCTAssertEqual(m.item(id: "vbi-enabled")?.isEnabled, true)
  }

  func test_vbi_disabledAndBadgedGame_whenTheGameDrivesIt() {
    let m = model(state { $0.vbiEnabled = true; $0.vbiOverride = .game })
    XCTAssertEqual(m.item(id: "vbi-enabled")?.isEnabled, false)
    XCTAssertEqual(m.item(id: "vbi-percent")?.isEnabled, false)
    XCTAssertEqual(m.item(id: "vbi-percent")?.badge, L("Game"))
  }

  // MARK: Validation

  func test_validateRows_absentUntilShown_andDisabledUntilTheirParentIsOn() {
    XCTAssertFalse(model(cir).allItems.contains { $0.id.contains("validate") })
    let off = model(cir, showValidation: true)
    XCTAssertEqual(off.item(id: "cir-validate-specialized-ops")?.isEnabled, true, "Specialized Ops defaults ON")
    XCTAssertEqual(off.item(id: "cir-validate-micro-op-fusion")?.isEnabled, false)
    let parentsOff = model(state { $0.jitAvailable = true; $0.engine = .cachedInterpreter; $0.cirSpecializedOps = false }, showValidation: true)
    XCTAssertEqual(parentsOff.item(id: "cir-validate-specialized-ops")?.isEnabled, false)
    let on = model(state { $0.jitAvailable = true; $0.engine = .cachedInterpreter; $0.cirSpecializedOps = true; $0.cirMicroOpFusion = true }, showValidation: true)
    XCTAssertEqual(on.item(id: "cir-validate-specialized-ops")?.isEnabled, true)
    XCTAssertEqual(on.item(id: "cir-validate-micro-op-fusion")?.isEnabled, true)
  }

  func test_irValidateRows_followTheirOwnParents() {
    let off = model(state { $0.jitAvailable = true; $0.engine = .cachedInterpreterIR; $0.cirPicLoadStore = false }, showValidation: true)
    XCTAssertEqual(off.item(id: "ir-validate-pic-load-store")?.isEnabled, false)
    XCTAssertEqual(off.item(id: "ir-validate-constant-address-fusion")?.isEnabled, false)
    let on = model(state { $0.jitAvailable = true; $0.engine = .cachedInterpreterIR; $0.cirPicLoadStore = true; $0.cirIrConstFusion = true }, showValidation: true)
    XCTAssertEqual(on.item(id: "ir-validate-pic-load-store")?.isEnabled, true)
    XCTAssertEqual(on.item(id: "ir-validate-constant-address-fusion")?.isEnabled, true)
  }

  func test_showValidationToggle_emitsShowValidation_notAFlag() {
    XCTAssertEqual(isOn(model(cir).item(id: "show-validation")), false)
    XCTAssertEqual(isOn(model(cir, showValidation: true).item(id: "show-validation")), true)
    guard case .toggle(let binding)? = model(cir).item(id: "show-validation")?.role else { return XCTFail("toggle") }
    binding.wrappedValue = true
    XCTAssertEqual(changes, [.showValidation(true)])
  }

  // MARK: Rows

  func test_resetOptimizations_emitsItsChange() {
    guard case .action(let run)? = model(cir).item(id: "reset-optimizations")?.role else { return XCTFail("action") }
    run()
    XCTAssertEqual(changes, [.resetOptimizationsToRecommended])
  }

  func test_rowIds_areUnique_inEveryEngineState() {
    for s in [cir, ir, jit, state { $0.engine = .jitARM64 }] {
      for shown in [false, true] {
        let ids = model(s, showValidation: shown).allItems.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "\(s.engine) validation \(shown)")
      }
    }
  }

  func test_everyRow_hasADescription() {
    for s in [cir, ir, jit] {
      for item in model(s, showValidation: true).allItems { XCTAssertFalse((item.description ?? "").isEmpty, item.id) }
    }
  }

  /// Toggle rows by id, each paired with the flag it must read and write.
  private let toggleRows: [(String, PerformanceTuningFlag)] = [
    ("mmu", .mmu), ("adaptive-clock", .adaptiveClock), ("pause-on-panic", .pauseOnPanic), ("accurate-cpu-cache", .writeBackCache),
    ("bypass-icache", .disableICache), ("ci-prefetch", .cachedInterpreterPrefetch), ("neon-texture-decode", .neonTextureDecode),
    ("dcbz-hack", .lowDCBZ), ("relaxed-idle", .relaxedIdleDetection), ("ff-ctr-idle", .fastForwardCtrIdle),
    ("sync-on-skip-idle", .syncOnSkipIdle), ("cpu-clock-enabled", .cpuClockEnabled), ("vbi-enabled", .vbiEnabled),
    ("cir-profiler", .cirProfile),
    ("pic-load-store", .cirPicLoadStore), ("specialized-ops", .cirSpecializedOps), ("block-linking", .cirBlockLinking),
    ("dynamic-links", .cirDynLinking), ("neon-paired-single-math", .cirPsNeon),
    ("cir-fp-load-store-specialization", .cirSpecializedFpLs), ("cir-paired-single-load-store-specialization", .cirSpecializedPsq),
    ("cir-fp-paired-single-arithmetic-specialization", .cirSpecializedFpArith), ("cir-micro-op-fusion", .cirMicroOpFusion),
    ("cir-dead-flag-elimination", .cirDeadFlagElim), ("cir-dead-fprf-elimination", .cirDeadFprfElim),
    ("cir-paired-single-float-fast-path", .cirPsqFastPath), ("cir-store-loop-memset-fast-path", .cirStoreLoopFF),
    ("cir-cache-management-loop-fast-forward", .cirCacheLoopFF),
    ("ir-constant-address-fusion", .cirIrConstFusion), ("ir-micro-op-fusion", .cirIrMicroOpFusion), ("ir-dead-cr-flag-elimination", .cirIrDeadFlagElim),
    ("validate-neon-paired-single-math", .cirPsNeonValidate),
    ("cir-validate-specialized-ops", .cirSpecializedOpsValidate), ("cir-validate-block-linking", .cirBlockLinkingValidate),
    ("cir-validate-micro-op-fusion", .cirMicroOpFusionValidate), ("cir-validate-dead-flag-elimination", .cirDeadFlagElimValidate),
    ("cir-validate-dead-fprf-elimination", .cirDeadFprfElimValidate), ("cir-validate-paired-single-float-fast-path", .cirPsqFastPathValidate),
    ("cir-validate-store-loop-fast-path", .cirStoreLoopFFValidate), ("cir-validate-cache-loop-fast-forward", .cirCacheLoopFFValidate),
    ("ir-validate-pic-load-store", .cirIrPicLoadStoreValidate), ("ir-validate-specialized-ops", .cirIrSpecializedOpsValidate),
    ("ir-validate-constant-address-fusion", .cirIrConstFusionValidate), ("ir-validate-micro-op-fusion", .cirIrMicroOpFusionValidate),
    ("ir-validate-dead-cr-flag-elimination", .cirIrDeadFlagElimValidate),
  ]

  func test_everyFlag_hasExactlyOneRow() {
    XCTAssertEqual(Set(toggleRows.map(\.1)), Set(PerformanceTuningFlag.allCases))
    XCTAssertEqual(toggleRows.count, PerformanceTuningFlag.allCases.count)
    let reachable = Set([cir, ir].flatMap { model($0, showValidation: true).allItems.map(\.id) })
    for (id, _) in toggleRows { XCTAssertTrue(reachable.contains(id), id) }
  }

  /// A mapping slip (a row wired to the wrong flag) fails here: each row reads its flag from the snapshot and emits its own.
  func test_everyToggleRow_readsAndEmitsItsOwnFlag() {
    for (id, flag) in toggleRows {
      let base = state { $0.jitAvailable = true; $0.engine = id.hasPrefix("ir-") ? .cachedInterpreterIR : .cachedInterpreter }
      var allOff = base
      var allOn = base
      for other in PerformanceTuningFlag.allCases { allOff[keyPath: other.keyPath] = false; allOn[keyPath: other.keyPath] = false }
      allOn[keyPath: flag.keyPath] = true
      XCTAssertEqual(isOn(model(allOn, showValidation: true).item(id: id)), true, "\(id) reads \(flag)")
      XCTAssertEqual(isOn(model(allOff, showValidation: true).item(id: id)), false, "\(id) reads only \(flag)")
      guard case .toggle(let binding)? = model(allOff, showValidation: true).item(id: id)?.role else { XCTFail("\(id) is not a toggle"); continue }
      changes = []
      binding.wrappedValue = true
      XCTAssertEqual(changes, [.flag(flag, true)], id)
    }
  }

  func test_flagKeyPaths_areDistinct() {
    var s = PerformanceTuningState()
    for flag in PerformanceTuningFlag.allCases { s[keyPath: flag.keyPath] = false }
    for flag in PerformanceTuningFlag.allCases {
      s[keyPath: flag.keyPath] = true
      XCTAssertEqual(PerformanceTuningFlag.allCases.filter { s[keyPath: $0.keyPath] }, [flag], "\(flag)")
      s[keyPath: flag.keyPath] = false
    }
  }
}
