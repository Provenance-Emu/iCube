// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

/// Covers `PauseMenuModelBuilder` (D18, `docs/superpowers/specs/2026-09-24-data-driven-menus-design.md`
/// §6 step 2): the pure builder behind the iOS pause menu's root pane. No
/// bridge calls happen inside the builder itself -- every action closure is a
/// recorded no-op here, matching the "snapshot in, actions in, model out"
/// shape `CheatsMenuModelBuilder` already established.
final class PauseMenuModelBuilderTests: XCTestCase {

  private static let expectedItemOrder = [
    "resume", "mute", "fast-forward", "save-states", "cheats",
    "controllers", "shaders", "continuity", "settings", "reset", "exit",
  ]

  private func noopActions() -> PauseMenuActions {
    PauseMenuActions(
      resume: {}, toggleMute: {}, openFastForwardPicker: {}, openSaveStates: {},
      openCheats: {}, openControllers: {}, openShaders: {}, openContinuity: {},
      openSettings: {}, requestReset: {}, requestExit: {}
    )
  }

  private func makeState(
    isMuted: Bool = false,
    fastForwardEnabled: Bool = false,
    fastForwardSubtitle: String = "Off — choose a speed to start",
    cheatsSubtitle: String = "Game enhancement codes"
  ) -> PauseMenuState {
    PauseMenuState(
      isMuted: isMuted,
      fastForwardEnabled: fastForwardEnabled,
      fastForwardSubtitle: fastForwardSubtitle,
      cheatsSubtitle: cheatsSubtitle
    )
  }

  // MARK: Item order

  /// The root pane has no per-system branching (mirroring `tvMainMenu`, which
  /// also lists the same rows regardless of GameCube vs Wii) -- this asserts
  /// that invariance directly, for two states shaped like what a GameCube
  /// title's vs. a Wii title's live pause-menu state would actually look like
  /// (a Wii title showing an active cheat and running fast-forward; a
  /// GameCube title with neither), rather than two identical inputs, which
  /// would prove nothing.
  func test_itemOrder_matchesExpectedSequence_forGameCubeAndWiiStates() {
    let gameCubeState = makeState()
    let wiiState = makeState(
      fastForwardEnabled: true,
      fastForwardSubtitle: "On at 2x — choose to change",
      cheatsSubtitle: "3 active"
    )

    let gcModel = PauseMenuModelBuilder.make(state: gameCubeState, actions: noopActions())
    let wiiModel = PauseMenuModelBuilder.make(state: wiiState, actions: noopActions())

    XCTAssertEqual(gcModel.allItems.map(\.id), Self.expectedItemOrder)
    XCTAssertEqual(wiiModel.allItems.map(\.id), Self.expectedItemOrder, "root pane item order must not vary by system/state")
  }

  func test_allItemsAreInASingleSection() {
    let model = PauseMenuModelBuilder.make(state: makeState(), actions: noopActions())
    XCTAssertEqual(model.sections.count, 1)
  }

  // MARK: Cheats subtitle ("N active" badge text)

  func test_cheatsSubtitle_reflectsActiveCount() {
    let model = PauseMenuModelBuilder.make(state: makeState(cheatsSubtitle: "3 active"), actions: noopActions())
    XCTAssertEqual(model.item(id: "cheats")?.subtitle, "3 active")
  }

  func test_cheatsSubtitle_fallsBackToGenericText_whenNoActiveCheats() {
    let model = PauseMenuModelBuilder.make(state: makeState(cheatsSubtitle: "Game enhancement codes"), actions: noopActions())
    XCTAssertEqual(model.item(id: "cheats")?.subtitle, "Game enhancement codes")
  }

  // MARK: Fast-forward subtitle

  func test_fastForwardSubtitle_passesThroughVerbatim_whenOff() {
    let model = PauseMenuModelBuilder.make(state: makeState(fastForwardSubtitle: "Off — choose a speed to start"), actions: noopActions())
    XCTAssertEqual(model.item(id: "fast-forward")?.subtitle, "Off — choose a speed to start")
    XCTAssertEqual(model.item(id: "fast-forward")?.icon, "forward")
  }

  func test_fastForwardSubtitle_passesThroughVerbatim_whenOn() {
    let model = PauseMenuModelBuilder.make(
      state: makeState(fastForwardEnabled: true, fastForwardSubtitle: "On at 3x — choose to change"),
      actions: noopActions()
    )
    XCTAssertEqual(model.item(id: "fast-forward")?.subtitle, "On at 3x — choose to change")
    XCTAssertEqual(model.item(id: "fast-forward")?.icon, "forward.fill")
  }

  // MARK: Mute title/icon flip

  func test_muteItem_reflectsMutedState() {
    let muted = PauseMenuModelBuilder.make(state: makeState(isMuted: true), actions: noopActions())
    XCTAssertEqual(muted.item(id: "mute")?.title, "Unmute")
    XCTAssertEqual(muted.item(id: "mute")?.icon, "speaker.slash.fill")

    let unmuted = PauseMenuModelBuilder.make(state: makeState(isMuted: false), actions: noopActions())
    XCTAssertEqual(unmuted.item(id: "mute")?.title, "Mute")
    XCTAssertEqual(unmuted.item(id: "mute")?.icon, "speaker.wave.2.fill")
  }

  // MARK: Destructive marking

  func test_resetAndExit_areMarkedDestructive() {
    let model = PauseMenuModelBuilder.make(state: makeState(), actions: noopActions())

    guard case .destructive = model.item(id: "reset")!.role else {
      return XCTFail("reset must be .destructive")
    }
    guard case .destructive = model.item(id: "exit")!.role else {
      return XCTFail("exit must be .destructive")
    }
  }

  func test_nonDestructiveItems_areNotMarkedDestructive() {
    let model = PauseMenuModelBuilder.make(state: makeState(), actions: noopActions())
    for id in ["resume", "mute", "fast-forward", "save-states", "cheats", "controllers", "shaders", "continuity", "settings"] {
      guard case .action = model.item(id: id)!.role else {
        XCTFail("\(id) must be .action, not .destructive")
        continue
      }
    }
  }

  // MARK: Actions wire through, not recomputed

  func test_actionClosures_areInvokedThroughPerformableRoles() {
    var resumed = false
    var reset = false
    var exited = false
    let actions = PauseMenuActions(
      resume: { resumed = true }, toggleMute: {}, openFastForwardPicker: {}, openSaveStates: {},
      openCheats: {}, openControllers: {}, openShaders: {}, openContinuity: {},
      openSettings: {}, requestReset: { reset = true }, requestExit: { exited = true }
    )
    let model = PauseMenuModelBuilder.make(state: makeState(), actions: actions)

    if case .action(let action) = model.item(id: "resume")!.role { action() }
    if case .destructive(let action) = model.item(id: "reset")!.role { action() }
    if case .destructive(let action) = model.item(id: "exit")!.role { action() }

    XCTAssertTrue(resumed)
    XCTAssertTrue(reset)
    XCTAssertTrue(exited)
  }

  // MARK: Every item carries an icon and a non-empty title

  func test_everyItem_hasIconAndTitle() {
    let model = PauseMenuModelBuilder.make(state: makeState(), actions: noopActions())
    for item in model.allItems {
      XCTAssertNotNil(item.icon, "\(item.id) should have an icon")
      XCTAssertFalse(item.title.isEmpty, "\(item.id) should have a title")
    }
  }
}
