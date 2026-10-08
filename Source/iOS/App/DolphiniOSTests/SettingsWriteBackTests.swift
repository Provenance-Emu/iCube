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

  /// Config changes save on a 0.8 s debounce. If the test process exits first, the still-dirty
  /// Base layer is saved from a static destructor during exit(), which locks a mutex that is
  /// already gone and aborts the test host ("recursive_mutex lock failed"). Save now instead.
  /// The host's Base layer before the test; the live tests below change real keys.
  private var savedBase: [String: String] = [:]

  override func setUp() {
    super.setUp()
    savedBase = DOLConfigBridge.baseLayerSnapshot()
  }

  override func tearDown() {
    DOLConfigBridge.restoreBaseLayerSnapshot(savedBase)
    DOLConfigBridge.flushSettingsToDisk()
    super.tearDown()
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

  // MARK: - No Config writes from onChange

  /// The bug this guards: a settings screen wrote Config from `.onChange(of:)`, which SwiftUI also
  /// runs for the values `configSynced` assigns, so a game INI's or the adaptive clock's value went
  /// back into Base as the user's own. Scans the settings screens and the in-game perf overlay for
  /// an `onChange` closure that calls a Config writer; use `Binding.onSet` on the control instead.
  func testNoOnChangeClosureWritesConfig() throws {
    let appRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let settings = appRoot.appendingPathComponent("Common/UI/Settings")
    // The sources are on the Mac: a simulator host can read them, a device host cannot.
    guard FileManager.default.fileExists(atPath: settings.path) else {
      throw XCTSkip("the repository is not reachable from this test host")
    }
    let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: settings, includingPropertiesForKeys: nil))
    var files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    files.append(appRoot.appendingPathComponent("Common/Swift/EmulationScreen.swift"))
    XCTAssertGreaterThan(files.count, 10, "the settings sources moved; point the scan at them")

    var offenders: [String] = []
    for file in files {
      let source = try String(contentsOf: file, encoding: .utf8)
      for body in Self.onChangeClosures(in: source) where body.range(of: Self.configWriter, options: .regularExpression) != nil {
        offenders.append("\(file.lastPathComponent): \(body.prefix(120))")
      }
    }
    XCTAssertEqual(offenders, [], "onChange closures that write Config")
  }

  private static let configWriter = #"DOL(Config|SettingsKey)Bridge\.(set|reset|delete|clear)"#

  /// The body of every `.onChange(of: ...) { ... }` closure in `source`.
  private static func onChangeClosures(in source: String) -> [Substring] {
    var bodies: [Substring] = []
    var searchStart = source.startIndex
    while let call = source.range(of: ".onChange(of:", range: searchStart ..< source.endIndex) {
      searchStart = call.upperBound
      guard let open = source[call.upperBound...].firstIndex(of: "{") else { break }
      var depth = 0
      var index = open
      while index < source.endIndex {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" {
          depth -= 1
          if depth == 0 { break }
        }
        index = source.index(after: index)
      }
      bodies.append(source[open ..< min(index, source.endIndex)])
    }
    return bodies
  }

  func testTheScanCatchesAConfigWriteInOnChange() {
    let leaky = """
    Picker("Role", selection: $role)
      .onChange(of: role) { _, value in
        if value == 1 { DOLConfigBridge.setDsuClientEnabled(false) }
      }
    Slider(value: $gain).onChange(of: gain) { UserDefaults.standard.set($0, forKey: "gain") }
    """
    let bodies = Self.onChangeClosures(in: leaky)
    XCTAssertEqual(bodies.count, 2)
    XCTAssertEqual(bodies.filter { $0.range(of: Self.configWriter, options: .regularExpression) != nil }.count, 1)
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
    XCTAssertEqual(DOLConfigBridge.efbScaleOverride(), .auto)
  }

  /// A running game's INI (per-game Internal Resolution, the shipped RHT / UGP / RDC overclocks)
  /// outranks Base too. The rows must show it as a "Game" override and disable the control, not
  /// look editable while an edit would change nothing for this game.
  func testAGameLayerCountsAsAnOverride() {
    XCTAssertEqual(DOLConfigBridge.efbScaleOverride(), .none)
    DOLConfigBridge.addTestGameLayer(withEfbScale: 3)
    defer { DOLConfigBridge.removeTestGameLayer() }

    XCTAssertEqual(DOLConfigBridge.gfxEfbScale(), 3)
    XCTAssertEqual(DOLConfigBridge.efbScaleOverride(), .game)
    // The game sets only OverclockEnable; the clock row still counts as overridden.
    XCTAssertEqual(DOLConfigBridge.overclockOverride(), .game)
    XCTAssertEqual(DOLConfigBridge.viOverclockOverride(), .none)

    // CurrentRun outranks the game: the adaptive clock / Auto-IR badge wins.
    DOLConfigBridge.setGfxEfbScaleAuto(4)
    defer { DOLConfigBridge.clearGfxEfbScaleAuto() }
    XCTAssertEqual(DOLConfigBridge.efbScaleOverride(), .auto)
  }

  /// "Recommended" deletes every CIR key, so each knob follows its compiled default, including
  /// Dynamic Links and NEON paired-single math (both default ON), which the old hand-kept
  /// "recommended" list switched off.
  func testResetToRecommendedRestoresCompiledDefaults() {
    DOLConfigBridge.setCirDynLinking(false)
    DOLConfigBridge.setCirPsNeon(false)
    DOLConfigBridge.setCirSpecializedOpsValidate(true)

    DOLConfigBridge.resetCirOptimizationsToDefaults()

    XCTAssertTrue(DOLConfigBridge.cirDynLinking())
    XCTAssertTrue(DOLConfigBridge.cirPsNeon())
    XCTAssertFalse(DOLConfigBridge.cirSpecializedOpsValidate())
    let leftover = DOLConfigBridge.baseLayerSnapshot().keys.filter { $0.lowercased().hasPrefix("dolphin.core.cir") }
    XCTAssertEqual(leftover, [])
  }
}
