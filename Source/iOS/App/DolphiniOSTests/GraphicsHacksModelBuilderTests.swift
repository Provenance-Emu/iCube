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

  /// Every toggle row emits its OWN change with the value written; a mapping slip in any closure fails here.
  func test_everyToggleRow_emitsItsOwnChange() {
    let expected: [(String, (Bool) -> GraphicsHacksChange)] = [
      ("bbox", { .bboxEnabled($0) }), ("efb-access", { .efbAccess($0) }), ("skip-efb-ram", { .skipEfbToRam($0) }),
      ("skip-xfb-ram", { .skipXfbToRam($0) }), ("immediate-xfb", { .immediateXfb($0) }),
      ("copy-efb-scaled", { .copyEfbScaled($0) }), ("early-xfb", { .earlyXfbOutput($0) }),
      ("skip-duplicate-xfb", { .skipDuplicateXFBs($0) }), ("efb-format-changes", { .efbFormatChanges($0) }),
      ("vertex-rounding", { .vertexRounding($0) }), ("force-progressive", { .forceProgressive($0) }),
      ("defer-efb-copies", { .deferEfbCopies($0) }), ("fast-texture-sampling", { .fastTextureSampling($0) }),
      ("fast-math", { .fastMath($0) }), ("compute-efb-xfb", { .useComputeEfbXfb($0) }),
      ("compute-vertex-decode", { .useComputeVertexDecode($0) }), ("no-mipmapping", { .noMipmapping($0) }),
      ("gpu-efb-peek", { .gpuEfbPeekResolve($0) }), ("vi-decimate-interlace", { .viDecimateInterlace($0) }),
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

  func test_cycleRows_emitTheirOwnChange() {
    guard case .cycle(_, let viSkip)? = model().item(id: "vi-skip")?.role,
          case .cycle(_, let bbox)? = model().item(id: "bbox-sync")?.role else { return XCTFail("cycle") }
    viSkip.wrappedValue = AnyHashable(ViSkipMode.on.rawValue)
    bbox.wrappedValue = AnyHashable(BboxSyncMode.forceSync.rawValue)
    XCTAssertEqual(changes, [.viSkipMode(1), .bboxSyncMode(1)])
  }

  func test_cycleOptions_useTheConfigRawValues() {
    guard case .cycle(let viSkip, _)? = model().item(id: "vi-skip")?.role,
          case .cycle(let bbox, _)? = model().item(id: "bbox-sync")?.role,
          case .cycle(let cache, _)? = model().item(id: "texture-cache")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(viSkip.map { $0.1 }, [AnyHashable(0), AnyHashable(1), AnyHashable(2)])
    XCTAssertEqual(bbox.map { $0.1 }, [AnyHashable(0), AnyHashable(1)])
    XCTAssertEqual(cache.map { $0.1 }, [AnyHashable(512), AnyHashable(128), AnyHashable(0)])
  }
}
