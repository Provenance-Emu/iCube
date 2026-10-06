// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest
@testable import iCube

/// Settings screens must not save what they only displayed. They seed @State from Config on every
/// Config change (`configSynced`) and write through `Binding.onSet`, which fires on a control's
/// own set only. They seed the clock and IR rows from Base, so an adaptive-clock or Auto-IR value
/// (CurrentRun) is never what gets written back.
final class SettingsWriteBackTests: XCTestCase {
  /// Stands in for a view's @State: `stored` is what sync assigns, `binding` what a control gets.
  private final class Box<Value> {
    var stored: Value
    init(_ value: Value) { stored = value }
    var binding: Binding<Value> { Binding(get: { self.stored }, set: { self.stored = $0 }) }
  }

  func testSeedingTheStateDoesNotWrite() {
    let state = Box(100)
    var writes: [Int] = []
    let control = state.binding.onSet { writes.append($0) }

    state.stored = 60 // what a configSynced sync() does
    XCTAssertEqual(control.wrappedValue, 60)
    XCTAssertEqual(writes, [])
  }

  func testAControlChangeWritesOnce() {
    let state = Box(false)
    var writes: [Bool] = []
    let control = state.binding.onSet { writes.append($0) }

    control.wrappedValue = true
    XCTAssertTrue(state.stored)
    XCTAssertEqual(writes, [true])
  }

  func testSettingTheSameValueDoesNotWrite() {
    let state = Box(3)
    var writes: [Int] = []
    let control = state.binding.onSet { writes.append($0) }

    control.wrappedValue = 3
    XCTAssertEqual(writes, [])
  }

  func testASliderOverAnIntWritesWholeSteps() {
    let state = Box(100)
    var writes: [Int] = []
    let slider = state.binding.onSet { writes.append($0) }.asDouble

    slider.wrappedValue = 100.4 // sub-step drag: same Int
    slider.wrappedValue = 120.0
    XCTAssertEqual(writes, [120])
    XCTAssertEqual(slider.wrappedValue, 120)
  }

  /// The Internal Resolution row seeds from Base: with Auto-IR / thermal overriding the scale on
  /// CurrentRun, the seed is still the user's own value, so writing it back changes nothing.
  func testTheEfbBaseGetterIgnoresTheAutoOverride() {
    let saved = DOLConfigBridge.baseLayerSnapshot()["Graphics.Settings.InternalResolution"]
    defer {
      DOLConfigBridge.clearGfxEfbScaleAuto()
      if let saved, let scale = Int(saved) {
        DOLConfigBridge.setGfxEfbScale(scale)
      } else {
        DOLConfigBridge.deleteBaseLayerKeys(["Graphics.Settings.InternalResolution"])
      }
    }
    DOLConfigBridge.setGfxEfbScale(2)
    DOLConfigBridge.setGfxEfbScaleAuto(4)

    XCTAssertEqual(DOLConfigBridge.gfxEfbScale(), 4)
    XCTAssertEqual(DOLConfigBridge.gfxEfbScaleBase(), 2)
    XCTAssertTrue(DOLConfigBridge.isEfbScaleAutoOverridden())
  }

  /// "Recommended" deletes every CIR key, so each knob follows its compiled default, including
  /// Dynamic Links (default ON), which the old hand-kept "recommended" list switched off.
  func testResetToRecommendedRestoresCompiledDefaults() {
    DOLConfigBridge.setCirDynLinking(false)
    DOLConfigBridge.setCirPsNeon(true)
    DOLConfigBridge.setCirSpecializedOpsValidate(true)

    DOLConfigBridge.resetCirOptimizationsToDefaults()

    XCTAssertTrue(DOLConfigBridge.cirDynLinking())
    XCTAssertFalse(DOLConfigBridge.cirPsNeon())
    XCTAssertFalse(DOLConfigBridge.cirSpecializedOpsValidate())
    let leftover = DOLConfigBridge.baseLayerSnapshot().keys.filter { $0.lowercased().hasPrefix("dolphin.core.cir") }
    XCTAssertEqual(leftover, [])
  }
}
