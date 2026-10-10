// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class GraphicsHacksModelBuilderTests: XCTestCase {
  private var changes: [GraphicsHacksChange] = []
  private func model(_ state: GraphicsHacksState = GraphicsHacksState()) -> MenuModel {
    GraphicsHacksModelBuilder.make(state: state) { self.changes.append($0) }
  }

  func test_rowOrder_matchesTheOldScreen() {
    XCTAssertEqual(model().allItems.map(\.id), [
      "texture-cache", "bbox", "bbox-sync", "efb-access", "skip-efb-ram", "skip-xfb-ram", "immediate-xfb",
      "copy-efb-scaled", "early-xfb", "skip-duplicate-xfb", "efb-format-changes", "vertex-rounding",
      "force-progressive", "defer-efb-copies", "vi-skip", "fast-texture-sampling", "fast-math",
      "compute-efb-xfb", "compute-vertex-decode", "no-mipmapping", "gpu-efb-peek", "vi-decimate-interlace",
    ])
  }

  func test_everyRow_hasADescription() {
    for item in model().allItems { XCTAssertFalse((item.description ?? "").isEmpty, item.id) }
  }

  func test_toggle_emitsTheMatchingChange() {
    guard case .toggle(let binding)? = model().item(id: "efb-access")?.role else { return XCTFail("toggle") }
    binding.wrappedValue = true
    XCTAssertEqual(changes, [.efbAccess(true)])
  }

  func test_textureCache_offersSafeDefaultFast_andEmitsTheSampleCount() {
    guard case .cycle(let options, let selection)? = model().item(id: "texture-cache")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["Safe", "Default", "Fast"])
    selection.wrappedValue = AnyHashable(512)
    XCTAssertEqual(changes, [.textureCacheSamples(512)])
  }

  func test_normalizedTextureCacheSamples_keepsSafeAndFast_mapsAnythingElseToDefault() {
    XCTAssertEqual(GraphicsHacksState.normalizedTextureCacheSamples(512), 512)
    XCTAssertEqual(GraphicsHacksState.normalizedTextureCacheSamples(0), 0)
    XCTAssertEqual(GraphicsHacksState.normalizedTextureCacheSamples(64), 128, "a stored 64 shows Default, not a dash")
    XCTAssertEqual(model(GraphicsHacksState(textureCacheSamples: 128)).item(id: "texture-cache")?.currentValueTitle, "Default")
  }

  func test_bboxRows_disabledWhenBackendLacksBbox() {
    var state = GraphicsHacksState()
    state.backendSupportsBbox = false
    let m = model(state)
    XCTAssertEqual(m.item(id: "bbox")?.isEnabled, false)
    XCTAssertEqual(m.item(id: "bbox-sync")?.isEnabled, false)
    XCTAssertTrue(m.item(id: "bbox")!.description!.contains("does not support"))
  }

  func test_bboxSync_disabledUntilBboxOn() {
    var state = GraphicsHacksState()
    state.bboxEnabled = false
    XCTAssertEqual(model(state).item(id: "bbox-sync")?.isEnabled, false)
    state.bboxEnabled = true
    XCTAssertEqual(model(state).item(id: "bbox-sync")?.isEnabled, true)
  }

  /// The OLD rule (`!immediateXfb && viSkipMode == 0`), probed at every VI Skip mode: only Off enables it, so
  /// the default state (Auto = 2) is disabled, exactly as the hand-built screen was.
  func test_skipDuplicateXfb_enabledOnlyWithViSkipOffAndNoImmediateXfb() {
    var state = GraphicsHacksState()
    state.immediateXfb = false
    for (mode, expected) in [(0, true), (1, false), (2, false)] {
      state.viSkipMode = mode
      XCTAssertEqual(model(state).item(id: "skip-duplicate-xfb")?.isEnabled, expected, "viSkipMode \(mode)")
    }
    state.viSkipMode = 0
    state.immediateXfb = true
    XCTAssertEqual(model(state).item(id: "skip-duplicate-xfb")?.isEnabled, false, "Immediate XFB disables it")
    XCTAssertEqual(GraphicsHacksState().viSkipMode, 2)
    XCTAssertEqual(model().item(id: "skip-duplicate-xfb")?.isEnabled, false, "the default state is disabled")
  }

  func test_deferEfbCopies_disabledWhenBothCopiesStayOnGPU() {
    var state = GraphicsHacksState()
    state.skipEfbToRam = true
    state.skipXfbToRam = true
    XCTAssertEqual(model(state).item(id: "defer-efb-copies")?.isEnabled, false)
    state.skipXfbToRam = false
    XCTAssertEqual(model(state).item(id: "defer-efb-copies")?.isEnabled, true)
  }
}
