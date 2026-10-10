// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class GraphicsAdvancedModelBuilderTests: XCTestCase {
  private var changes: [GraphicsAdvancedChange] = []
  private func model(_ state: GraphicsAdvancedState = GraphicsAdvancedState()) -> MenuModel {
    GraphicsAdvancedModelBuilder.make(state: state) { self.changes.append($0) }
  }
  private func state(_ edit: (inout GraphicsAdvancedState) -> Void) -> GraphicsAdvancedState {
    var s = GraphicsAdvancedState()
    edit(&s)
    return s
  }
  private func isOn(_ item: MenuItem?) -> Bool? {
    guard case .toggle(let binding)? = item?.role else { return nil }
    return binding.wrappedValue
  }

  /// Every Bool row, in screen order, with the flag it reads and writes.
  private let flagRows: [(String, GraphicsAdvancedFlag)] = [
    ("show-fps", .showFPS),
    ("show-vps", .showVPS),
    ("show-speed", .showSpeed),
    ("show-frame-times", .showFrameTimes),
    ("show-vblank-times", .showVBlankTimes),
    ("show-graphs", .showGraphs),
    ("log-render-time", .logRenderTime),
    ("speed-colors", .speedColors),
    ("overlay-stats", .overlayStats),
    ("api-validation-layer", .validationLayer),
    ("load-custom-textures", .hiresTextures),
    ("prefetch-custom-textures", .prefetchTextures),
    ("disable-efb-copy-to-vram", .disableEfbToVRAM),
    ("graphics-mods", .graphicsMods),
    ("crop", .cropPicture),
    ("progressive-scan", .progressiveScan),
    ("fast-depth", .fastDepth),
    ("per-pixel-lighting", .pixelLighting),
    ("backend-multithreading", .backendMT),
    ("shader-cache", .shaderCache),
    ("save-texture-cache-to-state", .saveTexCache),
    ("prefer-vs-for-lines", .preferVSForLines),
    ("cpu-culling", .cpuCull),
    ("defer-efb-invalidation", .deferEfbInvalidation)
  ]
  private let gib: UInt64 = 1 << 30

  // MARK: Structure

  func test_sections_inOrder_withHeadersAndFooters() {
    let m = model()
    XCTAssertEqual(m.sections.map(\.id), ["performance-statistics", "debugging", "shader-threads", "utility", "misc", "rendering", "experimental"])
    XCTAssertEqual(m.sections.map(\.header), ["Performance Statistics", "Debugging", "Shader Threads", "Utility", "Misc", "Rendering", "Experimental"])
    XCTAssertEqual(m.sections.map(\.footer), ["These overlays can also be toggled in-game from the pause menu.", nil, nil, nil, nil, nil,
                                              "⚠️ Experimental — may cause instability or glitches in some games."])
  }

  func test_rowOrder() {
    let expected = ["show-fps", "show-vps", "show-speed", "show-frame-times", "show-vblank-times", "show-graphs", "log-render-time", "speed-colors",
                    "overlay-stats", "api-validation-layer",
                    "compiler-threads", "precompiler-threads",
                    "load-custom-textures", "prefetch-custom-textures", "disable-efb-copy-to-vram", "graphics-mods",
                    "crop", "progressive-scan",
                    "fast-depth", "per-pixel-lighting", "backend-multithreading", "shader-cache", "save-texture-cache-to-state", "prefer-vs-for-lines", "cpu-culling",
                    "defer-efb-invalidation", "use-present-drawable", "manually-upload-buffers"]
    XCTAssertEqual(model().allItems.map(\.id), expected)
  }

  func test_everyRow_hasADescription() {
    let warning = model(state { $0.hiresTextures = true; $0.prefetchTextures = true; $0.texturePackBytes = Int64(gib); $0.physicalMemory = 2 * gib })
    for item in warning.allItems { XCTAssertFalse((item.description ?? "").isEmpty, item.id) }
  }

  // MARK: Flags

  func test_everyFlag_hasExactlyOneRow() {
    XCTAssertEqual(Set(flagRows.map { $0.1 }), Set(GraphicsAdvancedFlag.allCases))
    XCTAssertEqual(flagRows.count, GraphicsAdvancedFlag.allCases.count)
    XCTAssertEqual(Set(flagRows.map { $0.0 }).count, flagRows.count)
  }

  func test_flagKeyPaths_areDistinct() {
    var s = GraphicsAdvancedState()
    for flag in GraphicsAdvancedFlag.allCases { s[keyPath: flag.keyPath] = false }
    for flag in GraphicsAdvancedFlag.allCases {
      s[keyPath: flag.keyPath] = true
      XCTAssertEqual(GraphicsAdvancedFlag.allCases.filter { s[keyPath: $0.keyPath] }, [flag], "\(flag)")
      s[keyPath: flag.keyPath] = false
    }
  }

  func test_everyToggleRow_readsAndEmitsItsOwnFlag() {
    var allOn = GraphicsAdvancedState()
    var allOff = GraphicsAdvancedState()
    for flag in GraphicsAdvancedFlag.allCases { allOn[keyPath: flag.keyPath] = true; allOff[keyPath: flag.keyPath] = false }
    for (id, flag) in flagRows {
      XCTAssertEqual(isOn(model(allOn).item(id: id)), true, "\(id) reads \(flag)")
      XCTAssertEqual(isOn(model(allOff).item(id: id)), false, "\(id) reads only \(flag)")
      guard case .toggle(let binding)? = model(allOff).item(id: id)?.role else { XCTFail("\(id) is not a toggle"); continue }
      for value in [true, false] {
        changes = []
        binding.wrappedValue = value
        XCTAssertEqual(changes, [.flag(flag, value)], id)
      }
    }
  }

  func test_defaults_matchTheOldView() {
    let s = GraphicsAdvancedState()
    let on: Set<GraphicsAdvancedFlag> = [.fastDepth, .backendMT, .shaderCache]
    for flag in GraphicsAdvancedFlag.allCases { XCTAssertEqual(s[keyPath: flag.keyPath], on.contains(flag), "\(flag)") }
    XCTAssertEqual([s.compilerThreads, s.precompilerThreads, s.maxThreads], [1, 1, 2])
    XCTAssertEqual([s.usePresentDrawable, s.manuallyUploadBuffers], [2, 2])
  }

  func test_prefetch_disabledUntilCustomTexturesAreOn() {
    XCTAssertEqual(model().item(id: "prefetch-custom-textures")?.isEnabled, false)
    XCTAssertEqual(model(state { $0.hiresTextures = true }).item(id: "prefetch-custom-textures")?.isEnabled, true)
    XCTAssertEqual(model().item(id: "load-custom-textures")?.isEnabled, true)
  }

  // MARK: Shader threads

  func test_threadSteppers_useOneToMaxThreads_andEmitTheirOwnChange() {
    let m = model(state { $0.maxThreads = 5; $0.compilerThreads = 2; $0.precompilerThreads = 4 })
    let expected: [(String, Double, GraphicsAdvancedChange)] = [
      ("compiler-threads", 3, .compilerThreads(3)),
      ("precompiler-threads", 2, .precompilerThreads(2)),
    ]
    for (id, value, change) in expected {
      guard case .stepper(let stepper)? = m.item(id: id)?.role else { XCTFail("\(id) is not a stepper"); continue }
      XCTAssertEqual(stepper.range, 1 ... 5, id)
      XCTAssertEqual(stepper.step, 1, id)
      changes = []
      stepper.value.wrappedValue = value
      XCTAssertEqual(changes, [change], id)
    }
    XCTAssertEqual(m.item(id: "compiler-threads")?.currentValueTitle, "2")
    XCTAssertEqual(m.item(id: "precompiler-threads")?.currentValueTitle, "4")
  }

  func test_maxThreads_leavesACoreToTheEmulator() {
    for (count, expected) in [(0, 1), (1, 1), (2, 1), (3, 2), (6, 5)] {
      XCTAssertEqual(GraphicsAdvancedState.maxThreads(forProcessorCount: count), expected, "\(count) processors")
    }
  }

  func test_threadCount_unsetOrNegativeIsTwoCappedAtMax() {
    for (stored, max, expected) in [(-1, 5, 2), (0, 5, 2), (0, 1, 1), (-1, 1, 1), (3, 5, 3), (1, 5, 1)] {
      XCTAssertEqual(GraphicsAdvancedState.threadCount(stored: stored, maxThreads: max), expected, "stored \(stored), max \(max)")
    }
  }

  // MARK: Metal tri-states

  func test_triStateCycles_listOffOnAuto_andEmitTheirOwnChange() {
    let m = model(state { $0.usePresentDrawable = 2; $0.manuallyUploadBuffers = 0 })
    let expected: [(String, Int, GraphicsAdvancedChange, String)] = [
      ("use-present-drawable", 0, .presentDrawable(0), "Auto"),
      ("manually-upload-buffers", 1, .manuallyUploadBuffers(1), "Off"),
    ]
    for (id, raw, change, current) in expected {
      guard case .cycle(let options, let selection)? = m.item(id: id)?.role else { XCTFail("\(id) is not a cycle"); continue }
      XCTAssertEqual(options.map { $0.0 }, ["Off", "On", "Auto"], id)
      XCTAssertEqual(options.map { $0.1 }, [0, 1, 2].map { AnyHashable($0) }, id)
      XCTAssertEqual(m.item(id: id)?.currentValueTitle, current, id)
      changes = []
      selection.wrappedValue = AnyHashable(raw)
      XCTAssertEqual(changes, [change], id)
    }
  }

  func test_triState_aStoredValueOffTheList_isShownAsStored() {
    let m = model(state { $0.usePresentDrawable = 7 })
    guard case .cycle(let options, _)? = m.item(id: "use-present-drawable")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map { $0.0 }, ["Off", "On", "Auto", "7"])
    XCTAssertEqual(m.item(id: "use-present-drawable")?.currentValueTitle, "7")
    XCTAssertEqual(GraphicsAdvancedState.triStateRawValues(including: 1), [0, 1, 2])
  }

  // MARK: Texture-pack warning

  func test_isTooLargeToPrefetch_boundaries() {
    let ram = 8 * gib
    let quarter = Int64(ram / GraphicsAdvancedState.prefetchWarningRAMDivisor)
    XCTAssertEqual(GraphicsAdvancedState.prefetchWarningRAMDivisor, 4)
    XCTAssertFalse(GraphicsAdvancedState.isTooLargeToPrefetch(bytes: quarter, physicalMemory: ram), "exactly a quarter")
    XCTAssertTrue(GraphicsAdvancedState.isTooLargeToPrefetch(bytes: quarter + 1, physicalMemory: ram), "a byte over")
    XCTAssertFalse(GraphicsAdvancedState.isTooLargeToPrefetch(bytes: 0, physicalMemory: ram), "no packs")
    XCTAssertFalse(GraphicsAdvancedState.isTooLargeToPrefetch(bytes: -1, physicalMemory: ram), "a failed measurement")
    XCTAssertTrue(GraphicsAdvancedState.isTooLargeToPrefetch(bytes: Int64(3 * gib), physicalMemory: ram), "3 GiB of packs on an 8 GiB device")
    XCTAssertFalse(GraphicsAdvancedState.isTooLargeToPrefetch(bytes: Int64(gib), physicalMemory: ram))
  }

  func test_warningRow_showsOnlyWhenTexturesAndPrefetchAreOnAndThePackIsLarge() {
    let big = Int64(3 * gib)
    let cases: [(hires: Bool, prefetch: Bool, bytes: Int64, shown: Bool)] = [
      (true, true, big, true),
      (false, true, big, false),
      (true, false, big, false),
      (false, false, big, false),
      (true, true, Int64(gib), false),
      (true, true, 0, false),
    ]
    for c in cases {
      let m = model(state { $0.hiresTextures = c.hires; $0.prefetchTextures = c.prefetch; $0.texturePackBytes = c.bytes; $0.physicalMemory = 8 * gib })
      XCTAssertEqual(m.item(id: "texture-pack-warning") != nil, c.shown, "\(c)")
    }
  }

  func test_warningRow_sitsRightAfterPrefetch_isInert_andNamesTheSize() {
    let m = model(state { $0.hiresTextures = true; $0.prefetchTextures = true; $0.texturePackBytes = Int64(3 * gib); $0.physicalMemory = 8 * gib })
    let ids = m.section(containing: "texture-pack-warning")?.items.map(\.id)
    XCTAssertEqual(ids, ["load-custom-textures", "prefetch-custom-textures", "texture-pack-warning", "disable-efb-copy-to-vram", "graphics-mods"])
    let item = m.item(id: "texture-pack-warning")
    XCTAssertEqual(item?.isEnabled, false)
    let size = ByteCountFormatter.string(fromByteCount: Int64(3 * gib), countStyle: .file)
    XCTAssertEqual(item?.title, "Installed texture packs total \(size), a large share of this device's memory. Prefetching them can crash the game; turn Prefetch off or remove packs you don't use.")
    XCTAssertEqual(item?.description, item?.title)
    guard case .custom? = item?.role else { return XCTFail("custom") }
  }

  func test_warning_usesThePhysicalMemoryInTheState() {
    let packs = Int64(3 * gib)
    let on = { (ram: UInt64) in self.state { $0.hiresTextures = true; $0.prefetchTextures = true; $0.texturePackBytes = packs; $0.physicalMemory = ram } }
    XCTAssertTrue(on(8 * gib).showsTexturePackWarning)
    XCTAssertFalse(on(16 * gib).showsTexturePackWarning)
  }
}
