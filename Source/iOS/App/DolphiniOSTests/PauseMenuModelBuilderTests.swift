// DolphiniOSTests/PauseMenuModelBuilderTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

/// `PauseMenuModelBuilder` (unified menu UX spec §5): pure builder, three sections, every tile described.
final class PauseMenuModelBuilderTests: XCTestCase {
  private final class Box { var value: AnyHashable; init(_ v: AnyHashable) { value = v } }

  private func bindings(ff: Box = Box(PauseMenuModelBuilder.fastForwardOff), slot: Box = Box(3), muted: Box = Box(false), shader: Box = Box(ShaderQuickApply.noneValue)) -> PauseMenuBindings {
    PauseMenuBindings(
      mute: Binding(get: { muted.value as? Bool ?? false }, set: { muted.value = $0 }),
      fastForward: Binding(get: { ff.value }, set: { ff.value = $0 }),
      quickSlot: Binding(get: { slot.value }, set: { slot.value = $0 }),
      shader: Binding(get: { shader.value }, set: { shader.value = $0 }))
  }

  private var log: [String] = []
  private func actions() -> PauseMenuActions {
    PauseMenuActions(
      resume: { self.log.append("resume") }, quickSave: { self.log.append("save") }, quickLoad: { self.log.append("load") },
      screenshot: { self.log.append("shot") }, openSaveStates: {}, openCheats: {}, openControllers: {},
      openShaders: { self.log.append("shaders") }, openContinuity: {}, openSettings: {}, requestReset: {},
      requestExit: {}, recenterPointer: {})
  }

  private func state(recenter: Bool = false, cheats: Int = 0) -> PauseMenuState {
    PauseMenuState(
      quickSlot: 3, isMuted: false, activeCheatCount: cheats,
      shaderOptions: [("None", ShaderQuickApply.noneValue), ("crt", AnyHashable("/s/crt.slangp"))],
      showsRecenterPointer: recenter)
  }

  func test_threeSections_inOrder_withExpectedTiles() {
    let model = PauseMenuModelBuilder.make(state: state(), bindings: bindings(), actions: actions())
    XCTAssertEqual(model.sections.map(\.id), ["quick", "game", "system"])
    XCTAssertEqual(model.sections[0].items.map(\.id), ["resume", "quick-save", "quick-load", "fast-forward", "mute", "screenshot"])
    XCTAssertEqual(model.sections[1].items.map(\.id), ["save-states", "cheats", "shaders", "controllers", "continuity"])
    XCTAssertEqual(model.sections[2].items.map(\.id), ["settings", "reset", "exit"])
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
    XCTAssertEqual(with.sections[1].items.map(\.id), ["save-states", "cheats", "shaders", "controllers", "continuity", "recenter-pointer"])
  }

  func test_fastForward_isACycle_offFirst_fiveOptions() {
    let model = PauseMenuModelBuilder.make(state: state(), bindings: bindings(), actions: actions())
    guard case .cycle(let options, _)? = model.item(id: "fast-forward")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["Off", "2x", "4x", "8x", "Unlimited"])
    XCTAssertEqual(options.map(\.1), [AnyHashable(-1), AnyHashable(200), AnyHashable(400), AnyHashable(800), AnyHashable(0)])
  }

  func test_quickSave_badgeIsSlot_andLongPressOffersTenSlots() {
    let slot = Box(3)
    let model = PauseMenuModelBuilder.make(state: state(), bindings: bindings(slot: slot), actions: actions())
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
}
