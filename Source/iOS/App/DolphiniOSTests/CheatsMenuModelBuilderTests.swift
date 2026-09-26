// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class CheatsMenuModelBuilderTests: XCTestCase {

  private func actions(
    setEnabledGlobal: @escaping (Bool) -> Void = { _ in },
    requestEnableGlobalCheats: @escaping (CheatItem) -> Void = { _ in },
    toggleCheat: @escaping (CheatItem) -> Void = { _ in },
    downloadCheats: @escaping () -> Void = {},
    refreshCheats: @escaping () -> Void = {}
  ) -> CheatsMenuActions {
    CheatsMenuActions(
      setEnabledGlobal: setEnabledGlobal,
      requestEnableGlobalCheats: requestEnableGlobalCheats,
      toggleCheat: toggleCheat,
      downloadCheats: downloadCheats,
      refreshCheats: refreshCheats
    )
  }

  private func cheat(_ id: String, enabled: Bool = false) -> CheatItem {
    CheatItem(id: id, name: "Cheat \(id)", type: "Gecko Code", enabled: enabled, isGecko: true, index: 0)
  }

  // MARK: Download/Refresh always reachable (regression)

  /// Download is the ONLY way to bootstrap cheats for a game that has none
  /// yet. The D18 iOS proof-of-life pass gated the actions section on
  /// `hasAnyCheats`, verbatim from the pre-D18 iOS body -- harmless there
  /// only because iOS never had another way to reach Download either, but a
  /// real regression the moment tvOS (whose pre-D18 bespoke body always
  /// showed Download) shares this same builder. Fixed here: the actions
  /// section is unconditional.
  func test_zeroCheats_downloadAndRefreshStillFocusable() {
    let state = CheatsMenuState(cheatsEnabledGlobal: true, cheats: [])
    let model = CheatsMenuModelBuilder.make(state: state, actions: actions())
    XCTAssertTrue(model.focusableIDs.contains("download-cheats"))
    XCTAssertTrue(model.focusableIDs.contains("refresh-cheats"))
  }

  func test_withCheats_downloadAndRefreshStillFocusable() {
    let state = CheatsMenuState(cheatsEnabledGlobal: true, cheats: [cheat("gecko_0")])
    let model = CheatsMenuModelBuilder.make(state: state, actions: actions())
    XCTAssertTrue(model.focusableIDs.contains("download-cheats"))
    XCTAssertTrue(model.focusableIDs.contains("refresh-cheats"))
    XCTAssertTrue(model.focusableIDs.contains("cheat-gecko_0"))
  }

  // MARK: Empty state

  func test_zeroCheats_emptyStateIsPresentButNotFocusable() {
    let state = CheatsMenuState(cheatsEnabledGlobal: true, cheats: [])
    let model = CheatsMenuModelBuilder.make(state: state, actions: actions())
    let emptyItem = model.item(id: "empty-state")
    XCTAssertNotNil(emptyItem)
    XCTAssertEqual(emptyItem?.isEnabled, false, "the empty-state row is not itself focusable/activatable")
    XCTAssertFalse(model.focusableIDs.contains("empty-state"))
  }

  // MARK: Enable-cheats intercept (toggle binding's setter)

  /// Toggling a cheat ON while global cheats are disabled must request the
  /// enable-prompt instead of toggling the cheat directly.
  func test_toggleCheatOn_whileGlobalDisabled_requestsEnablePromptInsteadOfToggling() {
    var requested: CheatItem?
    var toggled: CheatItem?
    let state = CheatsMenuState(cheatsEnabledGlobal: false, cheats: [cheat("gecko_0")])
    let model = CheatsMenuModelBuilder.make(
      state: state,
      actions: actions(
        requestEnableGlobalCheats: { requested = $0 },
        toggleCheat: { toggled = $0 }
      )
    )
    guard case .toggle(let binding) = model.item(id: "cheat-gecko_0")?.role else {
      return XCTFail("expected a toggle role")
    }
    binding.wrappedValue = true
    XCTAssertEqual(requested?.id, "gecko_0")
    XCTAssertNil(toggled, "must not toggle directly while global cheats are off")
  }

  /// Same toggle-on, but with global cheats already enabled: toggles
  /// directly, no enable-prompt.
  func test_toggleCheatOn_whileGlobalEnabled_togglesDirectly() {
    var requested: CheatItem?
    var toggled: CheatItem?
    let state = CheatsMenuState(cheatsEnabledGlobal: true, cheats: [cheat("gecko_0")])
    let model = CheatsMenuModelBuilder.make(
      state: state,
      actions: actions(
        requestEnableGlobalCheats: { requested = $0 },
        toggleCheat: { toggled = $0 }
      )
    )
    guard case .toggle(let binding) = model.item(id: "cheat-gecko_0")?.role else {
      return XCTFail("expected a toggle role")
    }
    binding.wrappedValue = true
    XCTAssertNil(requested)
    XCTAssertEqual(toggled?.id, "gecko_0")
  }

  /// Toggling a cheat OFF never needs the prompt, even with global cheats
  /// disabled -- only turning one ON requires cheats to be enabled first.
  func test_toggleCheatOff_neverRequestsEnablePrompt() {
    var requested: CheatItem?
    var toggled: CheatItem?
    let state = CheatsMenuState(cheatsEnabledGlobal: false, cheats: [cheat("gecko_0", enabled: true)])
    let model = CheatsMenuModelBuilder.make(
      state: state,
      actions: actions(
        requestEnableGlobalCheats: { requested = $0 },
        toggleCheat: { toggled = $0 }
      )
    )
    guard case .toggle(let binding) = model.item(id: "cheat-gecko_0")?.role else {
      return XCTFail("expected a toggle role")
    }
    binding.wrappedValue = false
    XCTAssertNil(requested)
    XCTAssertEqual(toggled?.id, "gecko_0")
  }
}
