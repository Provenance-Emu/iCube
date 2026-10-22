// DolphiniOSTests/PauseMenuModelBuilderTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

/// `PauseMenuModelBuilder` (unified menu UX spec §5): pure builder, three sections, every tile described.
final class PauseMenuModelBuilderTests: XCTestCase {
  func test_manualChangeDisc_isReachableFromSharedPauseMenuAndPrimaryLayout() {
    let model = PauseMenuModelBuilder.make(state: state(), bindings: bindings(), actions: actions())
    XCTAssertNotNil(model.item(id: "change-disc"), "Both platforms need the live disc picker in the shared pause model")
    XCTAssertNotNil(PauseMenuModelBuilder.primaryLayout(model).item(id: "change-disc"))
    var count = 0
    var callbacks = actions()
    callbacks.openDiscPicker = { count += 1 }
    PauseMenuModelBuilder.make(state: state(), bindings: bindings(), actions: callbacks).item(id: "change-disc")?.activateInPlace()
    XCTAssertEqual(count, 1)
  }

  private final class Box { var value: AnyHashable; init(_ v: AnyHashable) { value = v } }

  private func bindings(ff: Box = Box(PauseMenuModelBuilder.fastForwardOff), slot: Box = Box(3), muted: Box = Box(false), shader: Box = Box(ShaderQuickApply.noneValue), resolution: Box = Box(1), volume: Box = Box(100), recording: Box = Box(false), perfHUD: Box = Box(false), engine: Box = Box(CpuEngine.cachedInterpreter.rawValue)) -> PauseMenuBindings {
    PauseMenuBindings(
      mute: Binding(get: { muted.value as? Bool ?? false }, set: { muted.value = $0 }),
      fastForward: Binding(get: { ff.value }, set: { ff.value = $0 }),
      quickSlot: Binding(get: { slot.value }, set: { slot.value = $0 }),
      shader: Binding(get: { shader.value }, set: { shader.value = $0 }),
      internalResolution: Binding(get: { resolution.value }, set: { resolution.value = $0 }),
      audioVolume: Binding(get: { volume.value }, set: { volume.value = $0 }),
      recording: Binding(get: { recording.value as? Bool ?? false }, set: { recording.value = $0 }),
      perfHUD: Binding(get: { perfHUD.value as? Bool ?? false }, set: { perfHUD.value = $0 }),
      cpuEngine: Binding(get: { engine.value }, set: { engine.value = $0 }))
  }

  private var log: [String] = []
  private func actions() -> PauseMenuActions {
    PauseMenuActions(
      resume: { self.log.append("resume") }, quickSave: { self.log.append("save") }, quickLoad: { self.log.append("load") },
      screenshot: { self.log.append("shot") }, openSaveStates: {}, openCheats: {}, openControllers: {},
      openShaders: { self.log.append("shaders") }, openContinuity: {}, openSettings: {}, openSettingsLeaf: { self.log.append("leaf:\($0.leafID)#\($0.rowID ?? "")") }, openPerfOverlay: { self.log.append("perf") }, openAudio: { self.log.append("audio") }, requestReset: {},
      requestExit: {}, recenterPointer: {})
  }

  private func state(recenter: Bool = false, cheats: Int = 0, resolution: Int = 1, metalFX: Bool = false, volume: Int = 100,
                     jit: Bool = false, nextEngine: CpuEngine = .cachedInterpreter) -> PauseMenuState {
    PauseMenuState(
      quickSlot: 3, isMuted: false, activeCheatCount: cheats,
      shaderOptions: [("None", ShaderQuickApply.noneValue), ("crt", AnyHashable("/s/crt.slangp"))],
      showsRecenterPointer: recenter,
      internalResolution: resolution, metalFXSupported: metalFX, audioVolume: volume, engineShortName: "CIR", jitAcquired: jit,
      nextEngine: nextEngine.rawValue)
  }

  func test_metalFXTile_followsUpscaling_onlyWhereSupported_andTogglesTheKey() {
    XCTAssertNil(PauseMenuModelBuilder.make(state: state(), bindings: bindings(), actions: actions()).item(id: "metalfx"))

    let metalFX = Box(false)
    var b = bindings()
    b.metalFX = Binding(get: { metalFX.value as? Bool ?? false }, set: { metalFX.value = $0 })
    let model = PauseMenuModelBuilder.make(state: state(metalFX: true), bindings: b, actions: actions())
    let ids = model.sections.flatMap(\.items).map(\.id)
    XCTAssertEqual(ids.firstIndex(of: "metalfx"), ids.firstIndex(of: "upscaling").map { $0 + 1 })
    guard case .toggle(let toggle) = model.item(id: "metalfx")!.role else { return XCTFail("toggle") }
    toggle.wrappedValue = true
    XCTAssertEqual(metalFX.value, AnyHashable(true))
    // The ladder stays plain scales: MetalFX stacks on whichever one is picked.
    guard case .cycle(let scales, _) = model.item(id: "upscaling")!.role else { return XCTFail("cycle") }
    XCTAssertEqual(scales.map(\.1), [1, 2, 3, 4, 6].map { AnyHashable($0) })
  }

  /// A value a settings leaf set off the tile ladder (volume 80, scale 5x) is listed in place, so one press
  /// steps to the next option instead of jumping to 0 % / Native.
  func test_offLadderValues_areListedInPlace_soOnePressSteps() {
    let model = PauseMenuModelBuilder.make(state: state(resolution: 5, volume: 80), bindings: bindings(), actions: actions())
    guard case .cycle(let scales, _) = model.item(id: "upscaling")!.role else { return XCTFail("cycle") }
    XCTAssertEqual(scales.map(\.1), [1, 2, 3, 4, 5, 6].map { AnyHashable($0) })
    XCTAssertEqual(scales[4].0, "5x")
    XCTAssertEqual(MenuItemRole.cycled(options: scales, current: AnyHashable(5), step: 1), AnyHashable(6))
    // The volume ladder moved to the Audio pane (`PauseAudioModelBuilderTests`); the tile badges the level.
    XCTAssertEqual(model.item(id: "audio")?.badge, "80 %")
  }

  func test_upscalingFitWindow_isListedFirst_andLadderValuesAddNothing() {
    let auto = PauseMenuModelBuilder.make(state: state(resolution: 0), bindings: bindings(), actions: actions())
    guard case .cycle(let scales, _) = auto.item(id: "upscaling")!.role else { return XCTFail("cycle") }
    XCTAssertEqual(scales.first?.0, "Fit Window")
    XCTAssertEqual(scales.first?.1, AnyHashable(0))
    XCTAssertEqual(scales.count, 6)
  }

  func test_threeSections_inOrder_withExpectedTiles() {
    let model = PauseMenuModelBuilder.make(state: state(), bindings: bindings(), actions: actions())
    XCTAssertEqual(model.sections.map(\.id), ["quick", "game", "system"])
    XCTAssertEqual(model.sections[0].items.map(\.id), ["resume", "quick-save", "quick-load", "save-states", "fast-forward", "mute", "screenshot", "record"])
    XCTAssertEqual(model.sections[1].items.map(\.id), ["change-disc", "perf-hud", "upscaling", "audio", "performance", "cheats", "shaders", "controllers", "continuity"])
    XCTAssertEqual(model.sections[2].items.map(\.id), ["settings", "reset", "exit"])
  }

  func test_record_tile_togglesRecordingBinding_andBadgesWhileOn() {
    let recording = Box(false)
    let off = PauseMenuModelBuilder.make(state: state(), bindings: bindings(recording: recording), actions: actions())
    let item = off.item(id: "record")!
    XCTAssertEqual(off.section(containing: "record")?.id, "quick")
    XCTAssertNil(item.badge)
    guard case .toggle(let binding) = item.role else { return XCTFail("record is not a toggle") }
    binding.wrappedValue = true
    XCTAssertEqual(recording.value, AnyHashable(true))
    let on = PauseMenuModelBuilder.make(state: state(), bindings: bindings(recording: recording), actions: actions())
    XCTAssertEqual(on.item(id: "record")?.badge, "REC")
  }

  func test_performanceTileOpensControlsWithoutChangingHUD() {
    let hud = Box(false)
    let model = PauseMenuModelBuilder.make(state: state(), bindings: bindings(perfHUD: hud), actions: actions())
    guard let item = model.item(id: "perf-hud") else { return XCTFail("Missing Performance") }
    XCTAssertEqual(item.title, "Performance")
    guard case .action = item.role else { return XCTFail("Performance must open its pane") }
    item.activateInPlace()
    XCTAssertEqual(log, ["perf"])
    XCTAssertEqual(hud.value, AnyHashable(false))
    XCTAssertEqual(model.item(id: "performance")?.title, "CPU Engine")
  }

  func test_perfHUDToggle_onDrawsFPSAndSpeed_offClearsEverything() {
    XCTAssertEqual(PerfHUDToggle.flags(on: true), PerfHUDToggle.Flags(fps: true, speed: true))
    XCTAssertFalse(PerfHUDToggle.flags(on: false).isOn)
    XCTAssertTrue(PerfHUDToggle.Flags(graphs: true).isOn, "any stat drawn counts as on")
  }

  func test_perfHUDVBlankAloneCountsAsOn_andMasterOffClearsIt() {
    XCTAssertTrue(PerfHUDToggle.Flags(vblank: true).isOn)
    XCTAssertFalse(PerfHUDToggle.flags(on: false).vblank)
  }

  func test_perfHUDLongPressRouteKeepsTVPauseParentOpen() {
    var calls: [String] = []
    PausePerfHUDRoute.open(platform: .tvos, openSubmenu: { calls.append("submenu") },
                           closePause: { calls.append("close") }, openTouchOverlay: { calls.append("touch") })
    XCTAssertEqual(calls, ["submenu"])
    calls = []
    PausePerfHUDRoute.open(platform: .ios, openSubmenu: { calls.append("submenu") },
                           closePause: { calls.append("close") }, openTouchOverlay: { calls.append("touch") })
    XCTAssertEqual(calls, ["close", "touch"])
  }

  func test_perfHUDSubmenuHasSixIndependentLiveToggles() {
    var flags = PerfHUDToggle.Flags()
    var writes = 0
    let model = PauseMenuModelBuilder.perfHUDModel(read: { flags }, write: { stat, on in
      flags[keyPath: stat.keyPath] = on
      writes += 1
    })
    XCTAssertEqual(model.allItems.count, 6)
    XCTAssertEqual(model.focusRequest, "hud-fps")
    for item in model.allItems {
      guard case .toggle(let binding) = item.role else { return XCTFail("HUD choice must be a toggle") }
      XCTAssertFalse(binding.wrappedValue)
    }
    XCTAssertEqual(writes, 0)
    model.item(id: "hud-vblank")?.activateInPlace()
    XCTAssertTrue(flags.vblank)
    XCTAssertEqual(writes, 1)
    guard case .toggle(let binding)? = model.item(id: "hud-vblank")?.role else { return XCTFail("VBlank") }
    flags.vblank = false
    XCTAssertFalse(binding.wrappedValue, "Existing menu bindings must reread external Config changes")
  }

  func test_upscaling_cyclesResolutions_andLongPressOpensGraphicsLeaf() {
    let resolution = Box(1)
    let model = PauseMenuModelBuilder.make(state: state(), bindings: bindings(resolution: resolution), actions: actions())
    let item = model.item(id: "upscaling")!
    XCTAssertEqual(model.section(containing: "upscaling")?.id, "game")
    guard case .cycle(let options, let selection) = item.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.1), [AnyHashable(1), AnyHashable(2), AnyHashable(3), AnyHashable(4), AnyHashable(6)])
    XCTAssertEqual(options.map(\.0).dropFirst(), ["2x", "3x", "4x", "6x"])
    selection.wrappedValue = AnyHashable(4)
    XCTAssertEqual(resolution.value, AnyHashable(4))
    guard case .action(let run)? = item.effectiveLongPress else { return XCTFail("long press") }
    run()
    XCTAssertEqual(log, ["leaf:graphics-enhancements#efb-scale"])
  }

  /// One Audio tile in place of Mute + a volume cycle: a tap opens the Audio pane, the badge is the level or
  /// "Muted", and the long-press still deep-links to the Audio leaf.
  func test_audio_opensTheAudioPane_badgesTheLevel_andLongPressOpensAudioLeaf() {
    let model = PauseMenuModelBuilder.make(state: state(volume: 50), bindings: bindings(), actions: actions())
    let item = model.item(id: "audio")!
    XCTAssertEqual(item.badge, "50 %")
    XCTAssertEqual(item.icon, "speaker.wave.2")
    guard case .action = item.role else { return XCTFail("action") }
    XCTAssertTrue(item.activateInPlace())
    XCTAssertEqual(log, ["audio"])
    log = []

    var muted = state()
    muted.isMuted = true
    let mutedItem = PauseMenuModelBuilder.make(state: muted, bindings: bindings(muted: Box(true)), actions: actions()).item(id: "audio")!
    XCTAssertEqual(mutedItem.badge, "Muted")
    XCTAssertEqual(mutedItem.icon, "speaker.slash.fill")

    guard case .action(let run)? = item.effectiveLongPress else { return XCTFail("long press") }
    run()
    XCTAssertEqual(log, ["leaf:audio#volume"])
  }

  /// The tile cycles the engine for the next launch in place; long-press opens Performance Tuning on the engine row.
  func test_performance_cyclesNextEngine_andLongPressOpensTuningOnEngineRow() {
    let engine = Box(CpuEngine.cachedInterpreter.rawValue)
    let model = PauseMenuModelBuilder.make(state: state(), bindings: bindings(engine: engine), actions: actions())
    let item = model.item(id: "performance")!
    XCTAssertEqual(item.currentValueTitle, "CIR")
    item.activateInPlace()
    XCTAssertEqual(engine.value, AnyHashable(CpuEngine.cachedInterpreterIR.rawValue))
    XCTAssertEqual(log, [])
    guard case .action(let run)? = item.effectiveLongPress else { return XCTFail("long press") }
    run()
    XCTAssertEqual(log, ["leaf:performance-tuning#cpu-engine"])
  }

  func test_engineOptions_offerTheJITOnlyWhenAcquired_andKeepAStoredInterpreterHonest() {
    XCTAssertEqual(PauseMenuModelBuilder.engineOptions(jitAcquired: false, including: CpuEngine.cachedInterpreter.rawValue).map(\.0),
                   ["CIR", "CIR-IR"])
    XCTAssertEqual(PauseMenuModelBuilder.engineOptions(jitAcquired: true, including: CpuEngine.jitARM64.rawValue).map(\.0),
                   ["JIT", "CIR", "CIR-IR"])
    let interpreter = PauseMenuModelBuilder.engineOptions(jitAcquired: false, including: CpuEngine.interpreter.rawValue)
    XCTAssertEqual(interpreter.map(\.0), ["INT", "CIR", "CIR-IR"])
    XCTAssertEqual(MenuItemRole.cycled(options: interpreter, current: AnyHashable(CpuEngine.interpreter.rawValue), step: 1),
                   AnyHashable(CpuEngine.cachedInterpreter.rawValue))
  }

  func test_everyTile_hasADescription() {
    let model = PauseMenuModelBuilder.make(state: state(recenter: true), bindings: bindings(), actions: actions())
    for item in model.allItems {
      XCTAssertFalse((item.description ?? "").isEmpty, "\(item.id) has no description")
    }
  }

  func test_recenterPointer_onlyWhenFlagged() {
    let without = PauseMenuModelBuilder.make(state: state(), bindings: bindings(), actions: actions())
    XCTAssertNil(without.item(id: "recenter-pointer"))
    let with = PauseMenuModelBuilder.make(state: state(recenter: true), bindings: bindings(), actions: actions())
    XCTAssertEqual(with.sections[1].items.map(\.id), ["change-disc", "perf-hud", "upscaling", "audio", "performance", "cheats", "shaders", "controllers", "continuity", "recenter-pointer"])
  }

  func test_fastForward_isACycle_offFirst_sixOptions() {
    let model = PauseMenuModelBuilder.make(state: state(), bindings: bindings(), actions: actions())
    guard case .cycle(let options, _)? = model.item(id: "fast-forward")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["Off", "2x", "3x", "4x", "8x", "Unlimited"])
    XCTAssertEqual(options.map(\.1), [AnyHashable(-1), AnyHashable(200), AnyHashable(300), AnyHashable(400), AnyHashable(800), AnyHashable(0)])
  }

  func test_quickSave_badgeIsSlot_andLongPressOffersTenSlots() {
    let slot = Box(3)
    var snapshot = state()
    snapshot.quickSaveMode = .slots
    let model = PauseMenuModelBuilder.make(state: snapshot, bindings: bindings(slot: slot), actions: actions())
    let item = model.item(id: "quick-save")!
    XCTAssertEqual(item.badge, "Slot 3")
    guard case .options(_, let options, let selection)? = item.effectiveLongPress else { return XCTFail("slot picker") }
    XCTAssertEqual(options.count, 10)
    selection.wrappedValue = AnyHashable(7)
    XCTAssertEqual(slot.value, AnyHashable(7))
    if case .action(let run) = item.role { run() }
    XCTAssertEqual(log, ["save"])
  }

  func test_mute_isAToggle() {
    let muted = Box(false)
    let model = PauseMenuModelBuilder.make(state: state(), bindings: bindings(muted: muted), actions: actions())
    guard case .toggle(let binding)? = model.item(id: "mute")?.role else { return XCTFail("toggle") }
    binding.wrappedValue = true
    XCTAssertEqual(muted.value, AnyHashable(true))
  }

  func test_shaders_cyclesOptions_andLongPressOpensFullPicker() {
    let model = PauseMenuModelBuilder.make(state: state(), bindings: bindings(), actions: actions())
    let item = model.item(id: "shaders")!
    guard case .cycle(let options, _) = item.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["None", "crt"])
    guard case .action(let run)? = item.effectiveLongPress else { return XCTFail("explicit long press") }
    run()
    XCTAssertEqual(log, ["shaders"])
  }

  func test_shaders_withNothingToCycle_isAPlainAction() {
    let lone = PauseMenuState(quickSlot: 3, isMuted: false, activeCheatCount: 0,
                              shaderOptions: [("None", ShaderQuickApply.noneValue)], showsRecenterPointer: false)
    let model = PauseMenuModelBuilder.make(state: lone, bindings: bindings(), actions: actions())
    let item = model.item(id: "shaders")!
    guard case .action(let run) = item.role else { return XCTFail("action") }
    run()
    XCTAssertEqual(log, ["shaders"])
    XCTAssertEqual(item.description, "Choose a post-processing shader.")
  }

  func test_cheatsBadge_showsActiveCount() {
    let model = PauseMenuModelBuilder.make(state: state(cheats: 3), bindings: bindings(), actions: actions())
    XCTAssertEqual(model.item(id: "cheats")?.badge, "3")
    let none = PauseMenuModelBuilder.make(state: state(), bindings: bindings(), actions: actions())
    XCTAssertNil(none.item(id: "cheats")?.badge)
  }

  func test_resetAndExit_areDestructive() {
    let model = PauseMenuModelBuilder.make(state: state(), bindings: bindings(), actions: actions())
    for id in ["reset", "exit"] {
      guard case .destructive = model.item(id: id)!.role else { return XCTFail("\(id) destructive") }
    }
  }

  func test_primaryLayout_primaryRowThenOptions_keepsEveryTileOnce() {
    let model = PauseMenuModelBuilder.make(state: state(), bindings: bindings(), actions: actions())
    let tv = PauseMenuModelBuilder.primaryLayout(model)
    XCTAssertEqual(tv.sections.map(\.id), ["primary", "options"])
    XCTAssertNil(tv.sections[0].header)
    XCTAssertEqual(tv.sections[0].items.map(\.id), ["resume", "perf-hud", "reset", "exit"])
    // Mute stays in `make` for the quick menu but leaves the pause grid: it lives on the Audio pane with Volume.
    XCTAssertEqual(tv.sections[1].items.map(\.id),
                   ["quick-save", "quick-load", "save-states", "fast-forward", "screenshot", "record", "change-disc", "upscaling", "audio", "performance", "cheats", "shaders",
                    "controllers", "continuity", "settings"])
    XCTAssertEqual(Set(tv.sections.flatMap(\.items).map(\.id)),
                   Set(model.sections.flatMap(\.items).map(\.id)).subtracting(PauseMenuModelBuilder.audioPaneIDs))
    XCTAssertEqual(PauseMenuModelBuilder.audioPaneIDs, ["mute"])
  }
}
