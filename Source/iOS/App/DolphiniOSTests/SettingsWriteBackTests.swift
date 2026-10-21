// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest
@testable import iCube

/// Settings screens must not save what they only displayed. They seed @State from Config on every
/// Config change (`configSynced`) and write through `Binding.onSet`, which fires on a control's
/// own set only. They seed the clock and IR rows from Base, so a game or adaptive-clock value
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

  func testGraphicsResetRestoresNativeResolution() {
    DOLConfigBridge.setGfxEfbScale(0) // Auto can multiply GPU work on high-density displays.
    DOLConfigBridge.resetPage(toDefaults: 1)
    XCTAssertEqual(DOLConfigBridge.gfxEfbScaleBase(), 1,
                   "Reset must restore the performance-safe Native default, not fit the display")
  }

  func testResetAllRestoresBoundingBoxDefault() throws {
    DOLConfigBridge.setGfxHackBboxEnable(true)
    XCTAssertTrue(DOLConfigBridge.gfxHackBboxEnable())

    try resetAllPreservingUserDefaults()

    XCTAssertFalse(DOLConfigBridge.gfxHackBboxEnable(), "Reset must remove the user's bounding-box override")
  }

  func testResetAllRestoresOptimizedTextureCacheDefault() throws {
    DOLConfigBridge.setGfxSafeTextureCacheColorSamples(512)
    XCTAssertEqual(DOLConfigBridge.gfxSafeTextureCacheColorSamples(), 512)

    try resetAllPreservingUserDefaults()

    XCTAssertEqual(DOLConfigBridge.gfxSafeTextureCacheColorSamples(), 0,
                   "Reset must match iCube's Fast launch default, rather than retaining Safe or falling back to 128")
  }

  func testResetAllRemovesSlotBMicrophone() throws {
    var snapshot = DOLConfigBridge.baseLayerSnapshot()
    snapshot["Dolphin.Core.SlotB"] = "4" // EXIDeviceType::Microphone
    DOLConfigBridge.restoreBaseLayerSnapshot(snapshot)
    XCTAssertTrue(DOLConfigBridge.mainSlotBMicrophone())

    try resetAllPreservingUserDefaults()

    XCTAssertFalse(DOLConfigBridge.mainSlotBMicrophone())
    XCTAssertNil(DOLConfigBridge.baseLayerSnapshot()["Dolphin.Core.SlotB"])
  }

  func testResetAllPreservesSlotBMemoryCardAssignments() throws {
    for device in ["1", "8"] { // EXIDeviceType::MemoryCard and MemoryCardFolder
      var snapshot = DOLConfigBridge.baseLayerSnapshot()
      snapshot["Dolphin.Core.SlotB"] = device
      DOLConfigBridge.restoreBaseLayerSnapshot(snapshot)

      try resetAllPreservingUserDefaults()

      XCTAssertEqual(DOLConfigBridge.baseLayerSnapshot()["Dolphin.Core.SlotB"], device,
                     "Gameplay reset must preserve the user's memory-card attachment")
    }
  }

  func testResetAllRestoresGeneralBootPreferences() throws {
    // Capture Dolphin's locale-derived fallback before installing any override. This is not
    // the Wii console's SYSCONF region and must not be hardcoded to NTSC-U in the reset.
    DOLConfigBridge.deleteBaseLayerKeys(["Dolphin.Core.FallbackRegion"])
    let localeFallback = DOLConfigBridge.mainFallbackRegion()
    XCTAssertEqual(localeFallback, DOLConfigBridge.defaultFallbackRegion())
    DOLConfigBridge.setMainEnableCheats(true)
    DOLConfigBridge.setMainOverrideRegionSettings(true)
    DOLConfigBridge.setMainAutoDiscChange(true)
    DOLConfigBridge.setMainFallbackRegion(localeFallback == 0 ? 1 : 0)
    XCTAssertTrue(DOLConfigBridge.mainEnableCheats())
    XCTAssertTrue(DOLConfigBridge.mainOverrideRegionSettings())
    XCTAssertTrue(DOLConfigBridge.mainAutoDiscChange())
    XCTAssertNotEqual(DOLConfigBridge.mainFallbackRegion(), localeFallback)

    try resetAllPreservingUserDefaults()

    XCTAssertFalse(DOLConfigBridge.mainEnableCheats())
    XCTAssertFalse(DOLConfigBridge.mainOverrideRegionSettings())
    XCTAssertFalse(DOLConfigBridge.mainAutoDiscChange())
    XCTAssertEqual(DOLConfigBridge.mainFallbackRegion(), localeFallback)
    let resetBase = DOLConfigBridge.baseLayerSnapshot()
    for key in ["EnableCheats", "OverrideRegionSettings", "AutoDiscChange", "FallbackRegion"] {
      XCTAssertNil(resetBase["Dolphin.Core.\(key)"], key)
    }
  }

  func testResetAllPreservesSDCardWriteProtection() throws {
    DOLConfigBridge.setMainAllowSDWrites(false)
    try resetAllPreservingUserDefaults()
    XCTAssertFalse(DOLConfigBridge.mainAllowSDWrites(),
                   "Resetting performance must not enable writes to a user's read-only SD card")
  }

  /// These Config regressions also exercise the public reset's UserDefaults cleanup. Restore the
  /// host's preferences afterwards, just as the fixture restores its Base Config layer.
  private func resetAllPreservingUserDefaults() throws {
    let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
    let defaults = UserDefaults.standard
    let saved = defaults.persistentDomain(forName: domain)
    defer {
      if let saved { defaults.setPersistentDomain(saved, forName: domain) }
      else { defaults.removePersistentDomain(forName: domain) }
    }
    DOLConfigBridge.resetAllToDefaults()
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

  /// The scale shown as the user's preference remains Base even when a game chooses another scale.
  func testTheEfbBaseGetterIgnoresGameOverrides() {
    DOLConfigBridge.setGfxEfbScale(2)
    DOLConfigBridge.addTestGameLayer(withEfbScale: 3)
    defer { DOLConfigBridge.removeTestGameLayer() }
    XCTAssertEqual(DOLConfigBridge.gfxEfbScale(), 3)
    XCTAssertEqual(DOLConfigBridge.gfxEfbScaleBase(), 2)
    XCTAssertEqual(DOLConfigBridge.efbScaleOverride(), .game)
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


  }

  /// A jitless boot puts the Cached Interpreter on CurrentRun for the run. Changed from the pause menu,
  /// the old SetBaseOrCurrent write landed there: the row showed the new engine, and the next game
  /// booted the old one. The choice must reach Base, and outside a game a CurrentRun copy must go.
  func testTheEngineChoiceReachesBasePastAJitlessBootCopy() {
    DOLConfigBridge.setMainCpuCore(CpuEngine.cachedInterpreter.rawValue)
    DOLConfigBridge.setMainCpuCoreCurrentRunForTesting(CpuEngine.interpreter.rawValue)
    XCTAssertEqual(DOLConfigBridge.mainCpuCore(), CpuEngine.interpreter.rawValue, "the test host has a CurrentRun layer")

    DOLConfigBridge.setMainCpuCore(CpuEngine.cachedInterpreterIR.rawValue)

    XCTAssertEqual(DOLConfigBridge.mainCpuCoreBase(), CpuEngine.cachedInterpreterIR.rawValue)
    XCTAssertEqual(DOLConfigBridge.mainCpuCore(), CpuEngine.cachedInterpreterIR.rawValue, "the CurrentRun copy no longer shadows Base")
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
