// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

/// Pause tiles that open Settings land on a real leaf and a real row in it, on both platforms' settings trees, and
/// every other tile acts in place or opens its own page.
final class PauseSettingsDeepLinkTests: XCTestCase {
  private var opened: [SettingsDeepLink] = []
  private var pages: [String] = []

  private func model() -> MenuModel {
    let bindings = PauseMenuBindings(mute: .constant(false), fastForward: .constant(PauseMenuModelBuilder.fastForwardOff),
                                     quickSlot: .constant(AnyHashable(1)), shader: .constant(ShaderQuickApply.noneValue))
    let actions = PauseMenuActions(
      resume: {}, quickSave: {}, quickLoad: {}, screenshot: {},
      openSaveStates: { self.pages.append("save-states") }, openCheats: { self.pages.append("cheats") },
      openControllers: { self.pages.append("controllers") }, openShaders: { self.pages.append("shaders") },
      openContinuity: { self.pages.append("continuity") }, openSettings: { self.pages.append("settings") },
      openSettingsLeaf: { self.opened.append($0) }, openPerfOverlay: { self.pages.append("perf-overlay") },
      requestReset: {}, requestExit: {}, recenterPointer: {})
    let state = PauseMenuState(quickSlot: 1, isMuted: false, activeCheatCount: 0,
                               shaderOptions: [("None", ShaderQuickApply.noneValue), ("crt", AnyHashable("/s/crt.slangp"))],
                               showsRecenterPointer: true, engineShortName: "CIR")
    return PauseMenuModelBuilder.make(state: state, bindings: bindings, actions: actions)
  }

  /// The table itself: tile → leaf → row.
  func test_table() {
    XCTAssertEqual(PauseMenuModelBuilder.settingsLinks, [
      "upscaling": SettingsDeepLink(leafID: "graphics-enhancements", rowID: "efb-scale"),
      "audio": SettingsDeepLink(leafID: "audio", rowID: "volume"),
      "performance": SettingsDeepLink(leafID: "performance-tuning", rowID: "cpu-engine"),
    ])
  }

  /// Each link names a leaf both settings trees have, and a row that leaf's model draws.
  func test_everyLink_resolvesToALeafAndRow_onIOSAndTVOS() {
    for isIOS in [true, false] {
      let entries = SettingsRootModelBuilder.sections(isIOS: isIOS, achievements: false).flatMap(\.entries)
      for (tile, link) in PauseMenuModelBuilder.settingsLinks {
        guard let leaf = entries.first(where: { $0.id == link.leafID }) else {
          XCTFail("\(tile): no leaf \(link.leafID) (isIOS \(isIOS))")
          continue
        }
        guard let row = link.rowID else { continue }
        guard let leafModel = leaf.makeModel?() else {
          XCTFail("\(tile): leaf \(link.leafID) has no model, so it cannot target row \(row)")
          continue
        }
        XCTAssertNotNil(leafModel.item(id: row), "\(tile): leaf \(link.leafID) has no row \(row) (isIOS \(isIOS))")
      }
    }
  }

  /// A linked tile's long-press opens exactly its link; the tap acts in place.
  func test_linkedTiles_longPressOpenTheirLink_andTapDoesNotOpenSettings() {
    let menu = model()
    for (tile, link) in PauseMenuModelBuilder.settingsLinks {
      opened = []
      guard let item = menu.item(id: tile) else { XCTFail("no tile \(tile)"); continue }
      item.activateInPlace()
      XCTAssertEqual(opened, [], "\(tile): a tap opened Settings")
      guard case .action(let run)? = item.effectiveLongPress else { XCTFail("\(tile): long-press is not an action"); continue }
      run()
      XCTAssertEqual(opened, [link], tile)
    }
  }

  /// Only these tiles open a page on a tap; everything else toggles, cycles or acts in place.
  func test_onlyPageTiles_openAPage() {
    let menu = model()
    for item in menu.allItems {
      pages = []
      opened = []
      item.activateInPlace()
      XCTAssertEqual(opened, [], "\(item.id) opened Settings on a tap")
      switch item.id {
      case "save-states", "cheats", "controllers", "continuity", "settings":
        XCTAssertEqual(pages, [item.id])
      default:
        XCTAssertEqual(pages, [], "\(item.id) opened \(pages) on a tap")
      }
    }
  }

  func test_rowTarget_isTakenOnce_andOnlyFromAScreenWithTheRow() {
    let target = SettingsRowTarget(rowID: "volume")
    XCTAssertTrue(target.isPending)
    XCTAssertNil(target.take(from: ["backend", "surround"]))
    XCTAssertEqual(target.take(from: ["backend", "volume"]), "volume")
    XCTAssertNil(target.take(from: ["backend", "volume"]))
    XCTAssertFalse(target.isPending)
  }
}
