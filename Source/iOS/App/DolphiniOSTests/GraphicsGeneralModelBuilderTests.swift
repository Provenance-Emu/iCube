// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class GraphicsGeneralModelBuilderTests: XCTestCase {
  private var changes: [GraphicsGeneralChange] = []
  private func model(_ state: GraphicsGeneralState = GraphicsGeneralState()) -> MenuModel {
    GraphicsGeneralModelBuilder.make(state: state) { self.changes.append($0) }
  }
  private func state(_ edit: (inout GraphicsGeneralState) -> Void) -> GraphicsGeneralState {
    var s = GraphicsGeneralState()
    edit(&s)
    return s
  }

  private let iosOnlyRows = ["frame-cap", "instant-replay", "save-clips-photos", "save-only-photos", "clip-length"]
  private let allRows = [
    "backend", "aspect-ratio", "vsync", "auto-ir-osd", "triple-buffering", "force-scale-one", "overscan-fullscreen",
    "async-present", "auto-ir", "target-fps", "min-scale", "max-scale", "frame-cap",
    "instant-replay", "save-clips-photos", "save-only-photos", "clip-length",
    "shader-compile-type", "compile-before-start",
  ]

  func test_rowOrder_isIOS() {
    XCTAssertEqual(model().allItems.map(\.id), allRows)
    XCTAssertEqual(model().sections.map(\.header), [nil, "Recording", "Shader Compilation"])
  }

  func test_rowOrder_notIOS() {
    let m = model(state { $0.isIOS = false })
    XCTAssertEqual(m.allItems.map(\.id), allRows.filter { !iosOnlyRows.contains($0) })
    XCTAssertEqual(m.sections.map(\.header), [nil, "Shader Compilation"])
    XCTAssertEqual(m.sections.map(\.id), ["general", "shader-compilation"])
  }

  func test_everyRow_hasADescription() {
    for item in model().allItems { XCTAssertFalse((item.description ?? "").isEmpty, item.id) }
  }

  func test_backendCycle_listsEveryBackend_andEmitsTheEnum() {
    guard case .cycle(let options, let selection)? = model().item(id: "backend")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map { $0.0 }, GraphicsBackend.allCases.map(\.label))
    selection.wrappedValue = AnyHashable(GraphicsBackend.vulkan)
    XCTAssertEqual(changes, [.backend(.vulkan)])
  }

  func test_vSync_toggleEmitsTheChange() {
    guard case .toggle(let binding)? = model().item(id: "vsync")?.role else { return XCTFail("toggle") }
    binding.wrappedValue = true
    XCTAssertEqual(changes, [.vSync(true)])
  }

  func test_scaleCycles_useTheInternalScaleLabels() {
    for id in ["min-scale", "max-scale"] {
      guard case .cycle(let options, _)? = model().item(id: id)?.role else { return XCTFail("\(id) cycle") }
      XCTAssertEqual(options.map { $0.0 }, ["1x", "2x", "3x", "4x"], id)
      XCTAssertEqual(options.map { $0.1 }, InternalScale.allCases.map { AnyHashable($0) }, id)
    }
    XCTAssertEqual(model().item(id: "min-scale")?.currentValueTitle, "1x")
    XCTAssertEqual(model().item(id: "max-scale")?.currentValueTitle, "2x")
  }

  func test_frameCapAndClipLength_offerTheOldChoices() {
    guard case .cycle(let cap, _)? = model().item(id: "frame-cap")?.role,
          case .cycle(let clip, _)? = model().item(id: "clip-length")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(cap.map { $0.0 }, ["System Default", "30", "60", "90", "120"])
    XCTAssertEqual(cap.map { $0.1 }, [0, 30, 60, 90, 120].map { AnyHashable($0) })
    XCTAssertEqual(clip.map { $0.0 }, ["5s", "10s", "15s", "30s"])
    XCTAssertEqual(clip.map { $0.1 }, [5, 10, 15, 30].map { AnyHashable($0) })
  }

  func test_tripleBuffering_defaultsOn() {
    XCTAssertTrue(GraphicsGeneralState().tripleBuffering)
    guard case .toggle(let binding)? = model().item(id: "triple-buffering")?.role else { return XCTFail("toggle") }
    XCTAssertTrue(binding.wrappedValue)
  }

  func test_photoToggles_reflectTheState() {
    func photoToggle(_ id: String, _ s: GraphicsGeneralState) -> Bool? {
      guard case .toggle(let binding)? = model(s).item(id: id)?.role else { return nil }
      return binding.wrappedValue
    }
    XCTAssertEqual(photoToggle("save-clips-photos", GraphicsGeneralState()), false)
    XCTAssertEqual(photoToggle("save-clips-photos", state { $0.saveClipsToPhotos = true }), true)
    XCTAssertEqual(photoToggle("save-only-photos", state { $0.saveClipsToPhotos = true }), false)
    XCTAssertEqual(photoToggle("save-only-photos", state { $0.saveOnlyToPhotos = true }), true)
  }

  func test_clipLength_defaultMatchesAnOption() {
    XCTAssertEqual(GraphicsGeneralState().clipSeconds, 15)
    XCTAssertEqual(model().item(id: "clip-length")?.currentValueTitle, "15s")
  }

  // MARK: Stored values (display only; the host's sync() reads them and writes nothing)

  func test_clipSeconds_unsetIsTheDefault_otherwiseShownAsStored() {
    for (stored, shown) in [(-5, 15), (0, 15), (1, 1), (7, 7), (10, 10), (20, 20), (60, 60)] {
      XCTAssertEqual(GraphicsGeneralState.storedClipSeconds(stored), shown, "stored \(stored)")
    }
  }

  func test_offLadderStoredValues_getTheirOwnOption_soTheRowNeverShowsADash() {
    let clip = model(state { $0.clipSeconds = 7 }).item(id: "clip-length")
    XCTAssertEqual(clip?.currentValueTitle, "7s")
    let cap = model(state { $0.frameCap = 45 }).item(id: "frame-cap")
    XCTAssertEqual(cap?.currentValueTitle, "45")
    XCTAssertEqual(GraphicsGeneralState.options([0, 30, 60], including: 45), [0, 30, 45, 60])
    XCTAssertEqual(GraphicsGeneralState.options([0, 30, 60], including: 30), [0, 30, 60])
  }

  func test_effectiveBackendKey_prefersASavedChoice() {
    XCTAssertEqual(GraphicsGeneralState.effectiveBackendKey(defaults: "Vulkan", config: "Metal"), "Vulkan")
    XCTAssertEqual(GraphicsGeneralState.effectiveBackendKey(defaults: "", config: "OGL"), "OGL")
    XCTAssertEqual(GraphicsGeneralState.effectiveBackendKey(defaults: nil, config: "Metal"), "Metal")
  }

  func test_backendKeys_roundTripThroughTheEnum() {
    for backend in GraphicsBackend.allCases { XCTAssertEqual(GraphicsBackend.from(key: backend.backendKey), backend) }
    XCTAssertEqual(GraphicsBackend.from(key: "garbage"), .metal, "an unknown key shows Metal")
  }

  // MARK: Emission

  func test_everyToggleRow_emitsItsOwnChange() {
    let expected: [(String, (Bool) -> GraphicsGeneralChange)] = [
      ("vsync", { .vSync($0) }), ("auto-ir-osd", { .showAutoIrOSD($0) }), ("triple-buffering", { .tripleBuffering($0) }),
      ("force-scale-one", { .forceScaleOneNonProMotion($0) }), ("overscan-fullscreen", { .overscanFullscreen($0) }),
      ("async-present", { .asyncPresent($0) }), ("auto-ir", { .autoIR($0) }), ("instant-replay", { .instantReplay($0) }),
      ("save-clips-photos", { .saveClipsToPhotos($0) }), ("save-only-photos", { .saveOnlyToPhotos($0) }),
      ("compile-before-start", { .compileBeforeStart($0) }),
    ]
    let m = model()
    for (id, change) in expected {
      guard case .toggle(let binding)? = m.item(id: id)?.role else { XCTFail("\(id) is not a toggle"); continue }
      for value in [true, false] {
        changes = []
        binding.wrappedValue = value
        XCTAssertEqual(changes, [change(value)], id)
      }
    }
  }

  func test_everyCycleRow_emitsItsOwnChange() {
    let expected: [(String, AnyHashable, GraphicsGeneralChange)] = [
      ("backend", AnyHashable(GraphicsBackend.opengl), .backend(.opengl)),
      ("aspect-ratio", AnyHashable(AspectRatio._16_9), .aspect(._16_9)),
      ("target-fps", AnyHashable(TargetFPS.fps120), .targetFPS(.fps120)),
      ("min-scale", AnyHashable(InternalScale.x3_0), .minScale(.x3_0)),
      ("max-scale", AnyHashable(InternalScale.x4_0), .maxScale(.x4_0)),
      ("frame-cap", AnyHashable(90), .frameCap(90)),
      ("clip-length", AnyHashable(30), .clipSeconds(30)),
      ("shader-compile-type", AnyHashable(ShaderCompileType.hybridUber), .shaderType(.hybridUber)),
    ]
    let m = model()
    for (id, value, change) in expected {
      guard case .cycle(_, let selection)? = m.item(id: id)?.role else { XCTFail("\(id) is not a cycle"); continue }
      changes = []
      selection.wrappedValue = value
      XCTAssertEqual(changes, [change], id)
    }
  }

  func test_cycleRows_showTheStateValue() {
    let m = model(state { $0.backend = .vulkan; $0.aspect = ._4_3; $0.targetFPS = .unlimited; $0.shaderType = .hybridUber; $0.frameCap = 120; $0.clipSeconds = 30 })
    XCTAssertEqual(m.item(id: "backend")?.currentValueTitle, "Vulkan")
    XCTAssertEqual(m.item(id: "aspect-ratio")?.currentValueTitle, "4:3")
    XCTAssertEqual(m.item(id: "target-fps")?.currentValueTitle, "Unlimited")
    XCTAssertEqual(m.item(id: "shader-compile-type")?.currentValueTitle, "Hybrid Ubershaders")
    XCTAssertEqual(m.item(id: "frame-cap")?.currentValueTitle, "120")
    XCTAssertEqual(m.item(id: "clip-length")?.currentValueTitle, "30s")
  }
}
