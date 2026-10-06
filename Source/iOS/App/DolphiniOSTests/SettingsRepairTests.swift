// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

/// The one-time settings repair: which Base-layer keys each rule deletes or keeps, the user-defaults
/// clean-up, and the once-per-install gate. Rules run against plain dictionaries (the Base layer as
/// "<system>.<section>.<key>" -> stored string), the gate against a fake store and a scratch suite.
final class SettingsRepairTests: XCTestCase {
  private func plan(_ base: [String: String], fastmem: Bool = true) -> [String] {
    SettingsRepair.baseKeysToDelete(base, fastmemAvailable: fastmem)
  }

  // MARK: - Rule table

  /// What a fresh install holds after its first launch: the DolphinCoreService seeds, as Dolphin
  /// writes them. None of it may be repaired, or every version bump would undo the launch seeds.
  func testACleanDefaultConfigHasNothingToRepair() {
    let clean = [
      "Dolphin.General.UseGameCovers": "True",
      "Dolphin.Core.Fastmem": "True",
      "Dolphin.Core.FastmemArena": "True",
      "Dolphin.Core.FastDiscSpeed": "True",
      "Dolphin.Core.DSPThread": "True",
      "Dolphin.Core.AccurateNaNs": "False",
      "Dolphin.Core.SyncGPU": "False",
      "Graphics.Hacks.EFBToTextureEnable": "True",
      "Graphics.Hacks.XFBToTextureEnable": "True",
      "Graphics.Hacks.ImmediateXFBEnable": "True",
      "Graphics.Hacks.VISkip": "False",
      "Graphics.Hacks.VISkipMode": "2",
      "Graphics.Settings.ShaderCompilerThreads": "2",
      "Graphics.Settings.ShaderPrecompilerThreads": "2",
      "Graphics.Settings.WaitForShadersBeforeStarting": "True",
      "Graphics.Hardware.AsyncPresent": "True",
    ]
    XCTAssertEqual(plan(clean), [])
    XCTAssertEqual(plan(clean, fastmem: false), [])
    XCTAssertEqual(plan([:]), [])
  }

  func testEveryCachedInterpreterKeyIsDeletedWhateverItsValueOrCase() {
    let base = [
      "Dolphin.Core.CIRDynLinking": "False",
      "Dolphin.Core.CIRBlockLinking": "True",
      "Dolphin.Core.CIRMicroOpFusionValidate": "True",
      "Dolphin.Core.CIRIRConstFusion": "True",
      "Dolphin.Core.CIRTapePrefetchDist": "64",
      "Dolphin.Core.CIRProfile": "True",
      "dolphin.core.cirpsneon": "true",
    ]
    XCTAssertEqual(Set(plan(base)), Set(base.keys))
  }

  func testUnconditionalKeysAreDeleted() {
    let base = [
      "Dolphin.Core.CachedInterpreterPrefetch": "True",
      "Dolphin.Core.StallMetrics": "False",
      "Dolphin.Core.RelaxedIdleDetection": "False",
      "Dolphin.Core.FastForwardCtrIdle": "False",
      "Dolphin.Core.SyncOnSkipIdle": "True",
      "Dolphin.Core.FpFast": "True",
      "Graphics.Hacks.NEONTextureDecode": "False",
    ]
    XCTAssertEqual(Set(plan(base)), Set(base.keys))
  }

  func testAccuracyAndSyncKeysAreDeletedOnlyWhenOn() {
    let keys = [
      "Dolphin.Core.SyncGPU", "Dolphin.Core.AccurateNaNs", "Dolphin.Core.AccurateCPUCache",
      "Dolphin.Core.DisableICache", "Dolphin.Core.LowDCBZHack", "Graphics.Hacks.VISkip",
    ]
    for key in keys {
      XCTAssertEqual(plan([key: "True"]), [key], key)
      XCTAssertEqual(plan([key: "1"]), [key], key)
      XCTAssertEqual(plan([key: "False"]), [], key)
    }
  }

  func testVISkipModeOnIsDeletedOffAndAutoAreKept() {
    let key = "Graphics.Hacks.VISkipMode"
    XCTAssertEqual(plan([key: "1"]), [key])
    XCTAssertEqual(plan([key: "0"]), [])
    XCTAssertEqual(plan([key: "2"]), [])
  }

  func testShaderModeShippedDefaultsAreDeletedChosenModesKept() {
    let key = "Graphics.Settings.ShaderCompilationMode"
    XCTAssertEqual(plan([key: "0"]), [key])
    XCTAssertEqual(plan([key: "2"]), [key])
    XCTAssertEqual(plan([key: "1"]), [])
    XCTAssertEqual(plan([key: "3"]), [])
  }

  func testFastmemOffIsDeletedOnlyWhereFastmemIsAvailable() {
    let base = ["Dolphin.Core.Fastmem": "False", "Dolphin.Core.FastmemArena": "False"]
    XCTAssertEqual(Set(plan(base, fastmem: true)), Set(base.keys))
    XCTAssertEqual(plan(base, fastmem: false), [])
    XCTAssertEqual(plan(["Dolphin.Core.Fastmem": "True"], fastmem: true), [])
  }

  func testCPUClockLeftoversAreDeletedAndADeliberateOverclockKept() {
    let clock = "Dolphin.Core.Overclock"
    let enable = "Dolphin.Core.OverclockEnable"
    let both = [clock, enable].sorted()
    // The adaptive clock's per-run underclock, saved by a settings screen.
    XCTAssertEqual(plan([clock: "0.6000000238", enable: "True"]), both)
    XCTAssertEqual(plan([clock: "0.6", enable: "False"]), both)
    XCTAssertEqual(plan([clock: "0.6"]), [clock])
    // Enabled at 100 %: a no-op that only pins the keys.
    XCTAssertEqual(plan([clock: "1", enable: "True"]), both)
    XCTAssertEqual(plan([clock: "0.9995", enable: "True"]), both)
    XCTAssertEqual(plan([clock: "1.0005", enable: "True"]), both)
    XCTAssertEqual(plan([enable: "True"]), [enable])
    // Off at 100 %, or a real overclock: kept.
    XCTAssertEqual(plan([clock: "1", enable: "False"]), [])
    XCTAssertEqual(plan([clock: "1.5", enable: "True"]), [])
    XCTAssertEqual(plan([clock: "1.5", enable: "False"]), [])
    XCTAssertEqual(plan([clock: "1.0015", enable: "True"]), [])
  }

  func testVIClockFollowsTheSameRules() {
    let clock = "Dolphin.Core.VIOverclock"
    let enable = "Dolphin.Core.VIOverclockEnable"
    XCTAssertEqual(plan([clock: "0.75", enable: "True"]), [clock, enable].sorted())
    XCTAssertEqual(plan([clock: "1.0", enable: "True"]), [clock, enable].sorted())
    XCTAssertEqual(plan([clock: "2.0", enable: "True"]), [])
  }

  /// Choices the owner wants kept, even with values the rules above would otherwise care about.
  func testUserChoicesAreNeverTouched() {
    let base = [
      "Dolphin.Core.CPUThread": "True",
      "Dolphin.Core.CPUCore": "5",
      "Dolphin.Core.GFXBackend": "Vulkan",
      "Dolphin.Core.EmulationSpeed": "0.5",
      "Dolphin.Core.EnableCheats": "True",
      "Dolphin.Core.FallbackRegion": "2",
      "Dolphin.Core.SelectedLanguage": "3",
      "Dolphin.Core.WiiSDCard": "False",
      "Dolphin.DSP.Volume": "40",
      "Graphics.Settings.InternalResolution": "3",
      "Graphics.Settings.AspectRatio": "2",
      "Graphics.Hardware.VSync": "False",
      "SYSCONF.IPL.LNG": "2",
      "Achievements.Achievements.Enabled": "True",
      "Wiimote.Settings.IRMode": "1",
    ]
    XCTAssertEqual(plan(base), [])
  }

  /// A key repaired once is gone, so a second pass over the result deletes nothing.
  func testRulesAreIdempotent() {
    var base = [
      "Dolphin.Core.CIRDynLinking": "False",
      "Dolphin.Core.Overclock": "0.6",
      "Dolphin.Core.OverclockEnable": "True",
      "Graphics.Settings.ShaderCompilationMode": "0",
      "Dolphin.Core.CPUThread": "True",
    ]
    for key in plan(base) { base.removeValue(forKey: key) }
    XCTAssertEqual(base, ["Dolphin.Core.CPUThread": "True"])
    XCTAssertEqual(plan(base), [])
  }

  // MARK: - User defaults

  private let suiteName = "SettingsRepairTests"
  private var defaults: UserDefaults!
  /// The host's Base layer before the test: the live tests below delete and change real keys.
  private var savedBase: [String: String] = [:]

  override func setUp() {
    super.setUp()
    UserDefaults().removePersistentDomain(forName: suiteName)
    defaults = UserDefaults(suiteName: suiteName)
    savedBase = DOLConfigBridge.baseLayerSnapshot()
  }

  override func tearDown() {
    UserDefaults().removePersistentDomain(forName: suiteName)
    // Put the host's Base layer back as it was, then save, leaving nothing unsaved behind (see
    // SettingsWriteBackTests.tearDown).
    DOLConfigBridge.restoreBaseLayerSnapshot(savedBase)
    DOLConfigBridge.flushSettingsToDisk()
    super.tearDown()
  }

  func testCleanUserDefaultsRemovesLearnedClocksAndABKeysOnly() {
    defaults.set(0.6, forKey: "adaptive_clock_cpu_GALE01")
    defaults.set(0.8, forKey: "adaptive_clock_vi_GALE01")
    defaults.set(true, forKey: "icube.cirProfile")
    defaults.set(true, forKey: "ICubeBenchServerEnabled")
    defaults.set(Data(), forKey: "icube.perfSnapshots")
    defaults.set(true, forKey: "adaptive_clock_enable")
    defaults.set(3, forKey: "adaptive_clock_schema_v")

    let removed = SettingsRepair.cleanUserDefaults(defaults)

    XCTAssertEqual(removed, ["ICubeBenchServerEnabled", "adaptive_clock_cpu_GALE01", "adaptive_clock_vi_GALE01",
                             "icube.cirProfile", "icube.perfSnapshots"])
    XCTAssertNil(defaults.object(forKey: "adaptive_clock_cpu_GALE01"))
    XCTAssertTrue(defaults.bool(forKey: "adaptive_clock_enable"))
    XCTAssertEqual(defaults.integer(forKey: "adaptive_clock_schema_v"), 5)
  }

  func testCleanUserDefaultsNeverLowersTheAdaptiveClockSchema() {
    defaults.set(7, forKey: "adaptive_clock_schema_v")
    SettingsRepair.cleanUserDefaults(defaults)
    XCTAssertEqual(defaults.integer(forKey: "adaptive_clock_schema_v"), 7)
  }

  // MARK: - Once per install

  private final class FakeStore: SettingsRepairConfigStore {
    var base: [String: String]
    /// What the files on disk hold: `base` as of the last save that reached the disk.
    var disk: [String: String]
    /// false: save() runs but the write never lands (a full disk, say).
    var saveReachesDisk = true
    /// false: the files exist but cannot be read back.
    var diskReadable = true
    var saves = 0
    var onSave: () -> Void = {}
    init(_ base: [String: String]) {
      self.base = base
      disk = base
    }

    func baseSnapshot() -> [String: String] { base }

    func deleteBaseKeys(_ keys: [String]) -> [String: String] {
      var deleted: [String: String] = [:]
      for key in keys { deleted[key] = base.removeValue(forKey: key) }
      return deleted
    }

    func save() {
      saves += 1
      if saveReachesDisk { disk = base }
      onSave()
    }

    func savedBaseSnapshot() -> [String: String]? { diskReadable ? disk : nil }
  }

  func testRunsOnceAndRecordsTheVersionOnlyAfterSaving() {
    let store = FakeStore(["Dolphin.Core.CIRDynLinking": "False", "Dolphin.Core.CPUThread": "True"])
    defaults.set(0.6, forKey: "adaptive_clock_cpu_GALE01")
    var versionAtSave: Int?
    store.onSave = { versionAtSave = self.defaults.integer(forKey: SettingsRepair.versionKey) }

    XCTAssertTrue(SettingsRepair.runIfNeeded(defaults: defaults, config: store, fastmemAvailable: true))
    XCTAssertEqual(versionAtSave, 0, "the version must not be recorded before the config is saved")
    XCTAssertEqual(store.base, ["Dolphin.Core.CPUThread": "True"])
    XCTAssertEqual(store.saves, 1)
    XCTAssertNil(defaults.object(forKey: "adaptive_clock_cpu_GALE01"))
    XCTAssertEqual(defaults.integer(forKey: SettingsRepair.versionKey), SettingsRepair.currentVersion)

    // Later launches skip it, even if a matching key has come back since.
    store.base["Dolphin.Core.CIRDynLinking"] = "False"
    XCTAssertFalse(SettingsRepair.runIfNeeded(defaults: defaults, config: store, fastmemAvailable: true))
    XCTAssertEqual(store.saves, 1)
    XCTAssertEqual(store.base["Dolphin.Core.CIRDynLinking"], "False")
  }

  /// A launch that died after saving but before recording the version repeats the repair next
  /// time; the second pass finds nothing left and completes.
  func testAnInterruptedRunCompletesOnTheNextLaunch() {
    let store = FakeStore(["Dolphin.Core.Overclock": "0.6", "Dolphin.Core.OverclockEnable": "True"])
    SettingsRepair.runIfNeeded(defaults: defaults, config: store, fastmemAvailable: true)
    defaults.removeObject(forKey: SettingsRepair.versionKey)

    XCTAssertTrue(SettingsRepair.runIfNeeded(defaults: defaults, config: store, fastmemAvailable: true))
    XCTAssertEqual(store.base, [:])
    XCTAssertEqual(defaults.integer(forKey: SettingsRepair.versionKey), SettingsRepair.currentVersion)
  }

  /// Config::Save reports no failure. When the deletions never reach the disk, the version stays
  /// unrecorded so the next launch, which loads the old file again, repeats the repair.
  func testAFailedSaveIsRetriedOnTheNextLaunch() {
    let store = FakeStore(["Dolphin.Core.CIRDynLinking": "False", "Dolphin.Core.CPUThread": "True"])
    store.saveReachesDisk = false
    defaults.set(0.6, forKey: "adaptive_clock_cpu_GALE01")

    XCTAssertTrue(SettingsRepair.runIfNeeded(defaults: defaults, config: store, fastmemAvailable: true))
    XCTAssertEqual(store.saves, 1)
    XCTAssertEqual(defaults.integer(forKey: SettingsRepair.versionKey), 0)
    // The defaults are cleaned once, on the run that sticks, not on every failed launch.
    XCTAssertEqual(defaults.double(forKey: "adaptive_clock_cpu_GALE01"), 0.6)

    // The next launch reloads what the disk still holds; this time the save lands.
    store.base = store.disk
    store.saveReachesDisk = true
    XCTAssertTrue(SettingsRepair.runIfNeeded(defaults: defaults, config: store, fastmemAvailable: true))
    XCTAssertEqual(store.disk, ["Dolphin.Core.CPUThread": "True"])
    XCTAssertNil(defaults.object(forKey: "adaptive_clock_cpu_GALE01"))
    XCTAssertEqual(defaults.integer(forKey: SettingsRepair.versionKey), SettingsRepair.currentVersion)
  }

  /// A file that exists but cannot be read back verifies nothing: like a failed save, the version
  /// and the defaults wait for the next launch.
  func testAnUnreadableSavedConfigIsRetriedOnTheNextLaunch() {
    let store = FakeStore(["Dolphin.Core.CIRDynLinking": "False"])
    store.diskReadable = false
    defaults.set(0.6, forKey: "adaptive_clock_cpu_GALE01")

    XCTAssertTrue(SettingsRepair.runIfNeeded(defaults: defaults, config: store, fastmemAvailable: true))
    XCTAssertEqual(defaults.integer(forKey: SettingsRepair.versionKey), 0)
    XCTAssertEqual(defaults.double(forKey: "adaptive_clock_cpu_GALE01"), 0.6)

    store.diskReadable = true
    XCTAssertTrue(SettingsRepair.runIfNeeded(defaults: defaults, config: store, fastmemAvailable: true))
    XCTAssertNil(defaults.object(forKey: "adaptive_clock_cpu_GALE01"))
    XCTAssertEqual(defaults.integer(forKey: SettingsRepair.versionKey), SettingsRepair.currentVersion)
  }

  /// A later rule runs once on installs that already ran v1, and the v1 rules do not run again:
  /// after v1 a key they match is the user's own choice.
  func testAVersionBumpRunsOnlyTheNewRules() {
    defaults.set(1, forKey: SettingsRepair.versionKey)
    defaults.set(0.6, forKey: "adaptive_clock_cpu_GALE01")
    let store = FakeStore([
      "Dolphin.Core.CIRDynLinking": "False",
      "Graphics.Settings.ShaderCompilationMode": "0",
      "Wiimote.Settings.FutureKey": "1",
    ])
    let v2Rules = SettingsRepair.configRules + [SettingsRepair.ConfigRule(key: "wiimote.settings.futurekey",
                                                                          condition: .always, since: 2)]

    XCTAssertTrue(SettingsRepair.runIfNeeded(defaults: defaults, config: store, fastmemAvailable: true,
                                             version: 2, configRules: v2Rules))

    XCTAssertEqual(store.base, ["Dolphin.Core.CIRDynLinking": "False", "Graphics.Settings.ShaderCompilationMode": "0"])
    XCTAssertEqual(defaults.double(forKey: "adaptive_clock_cpu_GALE01"), 0.6, "v1 defaults rules must not re-run")
    XCTAssertEqual(defaults.integer(forKey: SettingsRepair.versionKey), 2)
  }

  func testDefaultsRulesCanMatchOnValue() {
    defaults.set(true, forKey: "some_flag")
    defaults.set(false, forKey: "some_flag_off")
    let rules = [SettingsRepair.DefaultsRule(key: "some_flag", prefix: true, when: { ($0 as? Bool) == true }, since: 1)]
    XCTAssertEqual(SettingsRepair.cleanUserDefaults(defaults, rules: rules), ["some_flag"])
    XCTAssertNotNil(defaults.object(forKey: "some_flag_off"))
  }

  // MARK: - Live config (the test host's Base layer)

  /// The launch seeds must never write a value the rules delete, or the two fight on every
  /// install. Starts from a Base layer without any key a rule looks at, whatever the simulator's
  /// stored Dolphin.ini holds, seeds it the way a launch does and checks the rules pass it.
  func testTheLaunchSeedsNeedNoRepair() {
    let fastmem = FastmemManager.shared().fastmemAvailable
    let everyRuleKey = SettingsRepair.configRules.map {
      SettingsRepair.ConfigRule(key: $0.key, prefix: $0.prefix, condition: .always, since: $0.since)
    }
    let clockKeys = SettingsRepair.clockRules.flatMap { [$0.clock, $0.enable] }
    let ruled = SettingsRepair.baseKeysToDelete(DOLConfigBridge.baseLayerSnapshot(), fastmemAvailable: fastmem,
                                                configRules: everyRuleKey, clockRules: [])
    DOLConfigBridge.deleteBaseLayerKeys(ruled + clockKeys)

    DolphinCoreService.seedLaunchDefaults(fastmemAvailable: fastmem)

    XCTAssertEqual(SettingsRepair.baseKeysToDelete(DOLConfigBridge.baseLayerSnapshot(), fastmemAvailable: fastmem), [])
  }

  /// The read-back the repair trusts instead of Config::Save: a Base value, once saved, is in the
  /// on-disk snapshot under the same key.
  func testTheSavedSnapshotReadsBackTheFiles() {
    DOLConfigBridge.setCirDynTargetCache(true)
    DOLConfigBridge.flushSettingsToDisk()
    XCTAssertEqual(DOLConfigBridge.savedBaseConfigSnapshot()?["Dolphin.Core.CIRDynTargetCache"], "True")

    DOLConfigBridge.deleteBaseLayerKeys(["Dolphin.Core.CIRDynTargetCache"])
    DOLConfigBridge.flushSettingsToDisk()
    XCTAssertNotNil(DOLConfigBridge.savedBaseConfigSnapshot())
    XCTAssertNil(DOLConfigBridge.savedBaseConfigSnapshot()?["Dolphin.Core.CIRDynTargetCache"])
  }

  /// The tearDown restore the live tests rely on: deleted keys come back with their values, added
  /// keys go away.
  func testRestoringABaseSnapshotUndoesChanges() {
    DOLConfigBridge.setCirDynTargetCache(true)
    DOLConfigBridge.setMainOverclockPercent(150)
    let before = DOLConfigBridge.baseLayerSnapshot()

    DOLConfigBridge.deleteBaseLayerKeys(["Dolphin.Core.Overclock"]) // deleted
    DOLConfigBridge.setCirDynTargetCache(false) // changed
    DOLConfigBridge.setCirPsNeon(before["Dolphin.Core.CIRPsNeon"] != "True") // changed or added
    XCTAssertNotEqual(DOLConfigBridge.baseLayerSnapshot(), before)

    DOLConfigBridge.restoreBaseLayerSnapshot(before)
    XCTAssertEqual(DOLConfigBridge.baseLayerSnapshot(), before)
  }

  func testBridgeSnapshotAndDeleteRoundTrip() {
    DOLConfigBridge.setCirDynTargetCache(true)
    XCTAssertEqual(DOLConfigBridge.baseLayerSnapshot()["Dolphin.Core.CIRDynTargetCache"], "True")

    let deleted = DOLConfigBridge.deleteBaseLayerKeys(["dolphin.core.cirdyntargetcache"])

    XCTAssertEqual(deleted, ["Dolphin.Core.CIRDynTargetCache": "True"])
    XCTAssertNil(DOLConfigBridge.baseLayerSnapshot()["Dolphin.Core.CIRDynTargetCache"])
    XCTAssertFalse(DOLConfigBridge.cirDynTargetCache())
  }
}
