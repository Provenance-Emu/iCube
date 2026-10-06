// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One-time repair of settings that older builds saved by mistake. Runs once per install, at launch
/// (`DolphinCoreService`), before the launch defaults are seeded.
///
/// The settings screens used to write back whatever they displayed, so the adaptive clock's per-run
/// underclock, Performance A/B experiments and since-changed defaults were saved in Dolphin.ini and
/// GFX.ini as if the user had picked them, and no later default change reached those installs.
/// These rules delete such keys from the Base layer so each one falls back to its compiled default
/// (or to the launch seed). Deliberate choices are kept: a CPU overclock above 100 %, dual core, CPU
/// engine, backend, internal resolution, aspect, V-Sync, audio, speed, SYSCONF, RetroAchievements,
/// region and language, cheats, SD card, controllers and touch layouts.
@objc(ICubeSettingsRepair)
final class SettingsRepair: NSObject {
  /// Raise to run the rules once more on every install.
  static let currentVersion = 1
  static let versionKey = "settings_repair_v"
  /// The adaptive clock's own one-time purge (EmulationCoordinator) runs below this schema. The
  /// repair covers what it did, so it marks the schema current instead of letting it run later.
  static let adaptiveClockSchemaVersion = 5
  static let adaptiveClockSchemaKey = "adaptive_clock_schema_v"

  enum Condition: Equatable {
    /// Delete whatever the value.
    case always
    /// Delete when the stored bool is true.
    case whenTrue
    /// Delete when the stored integer is one of these.
    case whenInt(Set<Int>)
    /// Delete when the stored bool is false and this device has fastmem; the launch seed then
    /// writes the device's value again.
    case whenFalseWithFastmem
  }

  /// One Base-layer rule. `key` is "<system>.<section>.<key>" with Dolphin's system names
  /// ("Dolphin" is Dolphin.ini, "Graphics" is GFX.ini, "SYSCONF", ...), lowercased because
  /// Config::Location compares case-insensitively; with `prefix` it matches every key starting so.
  /// `since` is the repair version that introduced the rule: an install runs only the rules newer
  /// than the version it already ran, because after v1 the screens no longer leak values, so a key
  /// an old rule matches is by then the user's own choice.
  struct ConfigRule {
    let key: String
    var prefix = false
    let condition: Condition
    let since: Int
  }

  // To repair another key: append a row with `since: currentVersion + 1`, raise `currentVersion`,
  // and add the key to SettingsRepairTests.
  static let configRules: [ConfigRule] = [
    // Every Cached Interpreter knob: the optimizations, their Validate twins, the IR engine's, and
    // the tape, profiler, tail-link and perf-monitor knobs.
    ConfigRule(key: "dolphin.core.cir", prefix: true, condition: .always, since: 1),
    ConfigRule(key: "dolphin.core.cachedinterpreterprefetch", condition: .always, since: 1),
    ConfigRule(key: "dolphin.core.stallmetrics", condition: .always, since: 1),
    ConfigRule(key: "dolphin.core.relaxedidledetection", condition: .always, since: 1),
    ConfigRule(key: "dolphin.core.fastforwardctridle", condition: .always, since: 1),
    ConfigRule(key: "dolphin.core.synconskipidle", condition: .always, since: 1),
    ConfigRule(key: "dolphin.core.fpfast", condition: .always, since: 1),
    ConfigRule(key: "graphics.hacks.neontexturedecode", condition: .always, since: 1),
    ConfigRule(key: "dolphin.core.syncgpu", condition: .whenTrue, since: 1),
    ConfigRule(key: "dolphin.core.accuratenans", condition: .whenTrue, since: 1),
    ConfigRule(key: "dolphin.core.accuratecpucache", condition: .whenTrue, since: 1),
    ConfigRule(key: "dolphin.core.disableicache", condition: .whenTrue, since: 1),
    ConfigRule(key: "dolphin.core.lowdcbzhack", condition: .whenTrue, since: 1),
    ConfigRule(key: "graphics.hacks.viskip", condition: .whenTrue, since: 1),
    // TriState: 0 Off, 1 On, 2 Auto. On was never a default; Auto is the launch seed.
    ConfigRule(key: "graphics.hacks.viskipmode", condition: .whenInt([1]), since: 1),
    // 0 Specialized and 2 Hybrid Ubershaders were each the shipped default; 1 (Exclusive) and
    // 3 (Skip Drawing) are only ever chosen.
    ConfigRule(key: "graphics.settings.shadercompilationmode", condition: .whenInt([0, 2]), since: 1),
    ConfigRule(key: "dolphin.core.fastmem", condition: .whenFalseWithFastmem, since: 1),
    ConfigRule(key: "dolphin.core.fastmemarena", condition: .whenFalseWithFastmem, since: 1),
  ]

  /// (clock, enable) pairs. A clock below 100 % is the adaptive clock's leftover; an enabled clock
  /// at 100 % does nothing but pin the key. A clock above 100 % is a deliberate overclock and stays.
  struct ClockRule {
    let clock: String
    let enable: String
    let since: Int
  }

  static let clockRules = [
    ClockRule(clock: "dolphin.core.overclock", enable: "dolphin.core.overclockenable", since: 1),
    ClockRule(clock: "dolphin.core.vioverclock", enable: "dolphin.core.vioverclockenable", since: 1),
  ]
  static let clockNeutralTolerance: Float = 0.001

  /// One user-defaults rule: a key, or with `prefix` every key starting so, removed when `when`
  /// (if any) accepts its value. Versioned like `ConfigRule`.
  struct DefaultsRule {
    let key: String
    var prefix = false
    var when: ((Any) -> Bool)?
    let since: Int
  }

  static let defaultsRules: [DefaultsRule] = [
    // Per-game learned adaptive clocks: each game relearns its clock on its next boot.
    DefaultsRule(key: "adaptive_clock_cpu_", prefix: true, since: 1),
    DefaultsRule(key: "adaptive_clock_vi_", prefix: true, since: 1),
    // Written only by the Performance A/B tools.
    DefaultsRule(key: "icube.cirProfile", since: 1),
    DefaultsRule(key: "ICubeBenchServerEnabled", since: 1),
    DefaultsRule(key: "icube.perfSnapshots", since: 1),
  ]

  /// The Base-layer keys to delete. `base` maps each key present in the Base layer
  /// ("Dolphin.Core.Overclock") to its stored string; the result uses the same spelling. Only rules
  /// newer than `afterVersion` apply.
  static func baseKeysToDelete(_ base: [String: String], fastmemAvailable: Bool, afterVersion: Int = 0,
                               configRules: [ConfigRule] = SettingsRepair.configRules,
                               clockRules: [ClockRule] = SettingsRepair.clockRules) -> [String] {
    var byLowercased: [String: String] = [:]
    for key in base.keys {
      byLowercased[key.lowercased()] = key
    }
    let rules = configRules.filter { $0.since > afterVersion }
    var doomed = Set<String>()
    for (lowered, key) in byLowercased {
      guard let value = base[key] else { continue }
      let matches = rules.filter { $0.prefix ? lowered.hasPrefix($0.key) : lowered == $0.key }
      if matches.contains(where: { shouldDelete(value, condition: $0.condition, fastmemAvailable: fastmemAvailable) }) {
        doomed.insert(key)
      }
    }
    for rule in clockRules where rule.since > afterVersion {
      let clockKey = byLowercased[rule.clock]
      let enableKey = byLowercased[rule.enable]
      // An absent key reads as its compiled default: clock 1.0, enable false.
      let clock = clockKey.flatMap { base[$0] }.flatMap(parseFloat) ?? 1.0
      let enabled = enableKey.flatMap { base[$0] }.flatMap(parseBool) ?? false
      let leftoverUnderclock = clock < 1.0
      let enabledButNeutral = enabled && abs(clock - 1.0) <= clockNeutralTolerance
      if leftoverUnderclock || enabledButNeutral {
        doomed.formUnion([clockKey, enableKey].compactMap { $0 })
      }
    }
    return doomed.sorted()
  }

  /// Removes the user-defaults keys the rules newer than `afterVersion` match, and marks the
  /// adaptive clock's own purge as done. Returns the removed keys.
  @discardableResult
  static func cleanUserDefaults(_ defaults: UserDefaults, afterVersion: Int = 0,
                                rules: [DefaultsRule] = SettingsRepair.defaultsRules) -> [String] {
    let active = rules.filter { $0.since > afterVersion }
    var removed: [String] = []
    for (key, value) in defaults.dictionaryRepresentation() {
      let matched = active.contains { rule in
        (rule.prefix ? key.hasPrefix(rule.key) : key == rule.key) && (rule.when?(value) ?? true)
      }
      // dictionaryRepresentation also lists registered and global defaults; only remove stored ones.
      if matched, defaults.object(forKey: key) != nil {
        defaults.removeObject(forKey: key)
        removed.append(key)
      }
    }
    if defaults.integer(forKey: adaptiveClockSchemaKey) < adaptiveClockSchemaVersion {
      defaults.set(adaptiveClockSchemaVersion, forKey: adaptiveClockSchemaKey)
    }
    return removed.sorted()
  }

  static func isNeeded(in defaults: UserDefaults, version: Int = currentVersion) -> Bool {
    defaults.integer(forKey: versionKey) < version
  }

  /// Runs the repair once per install version. The defaults are cleaned and the version recorded
  /// last, after the config is saved, so a launch that dies part-way repeats the repair on the
  /// next launch; the rules are idempotent, so a second pass deletes nothing more. Config::Save
  /// reports no failure, so both wait until the files read back from disk hold nothing the rules
  /// would still delete; otherwise the next launch tries again. Touches only
  /// Base-layer config keys and the defaults above, never save states, NAND, game files,
  /// controller profiles or touch layouts. Returns whether it ran.
  @discardableResult
  static func runIfNeeded(defaults: UserDefaults, config: SettingsRepairConfigStore, fastmemAvailable: Bool,
                          version: Int = currentVersion, configRules: [ConfigRule] = SettingsRepair.configRules) -> Bool {
    guard isNeeded(in: defaults, version: version) else { return false }
    let previousVersion = defaults.integer(forKey: versionKey)
    let doomed = baseKeysToDelete(config.baseSnapshot(), fastmemAvailable: fastmemAvailable,
                                  afterVersion: previousVersion, configRules: configRules)
    let deleted = config.deleteBaseKeys(doomed)
    config.save()
    let unsaved = baseKeysToDelete(config.savedBaseSnapshot(), fastmemAvailable: fastmemAvailable,
                                   afterVersion: previousVersion, configRules: configRules)
    for key in deleted.keys.sorted() {
      NSLog("[SettingsRepair] deleted %@ (was %@)", key, deleted[key] ?? "")
    }
    // Retried on the next launch; the defaults wait for that run, so a disk that keeps refusing the
    // write does not wipe the learned clocks on every launch.
    guard unsaved.isEmpty else {
      NSLog("[SettingsRepair] v%ld -> v%ld not recorded: the saved config still holds %@; retrying next launch",
            previousVersion, version, unsaved.joined(separator: ", "))
      return true
    }
    let removedDefaults = cleanUserDefaults(defaults, afterVersion: previousVersion)
    defaults.set(version, forKey: versionKey)
    NSLog("[SettingsRepair] v%ld -> v%ld: %ld config keys deleted, %ld defaults removed",
          previousVersion, version, deleted.count, removedDefaults.count)
    SentryTelemetryService.recordSettingsRepair(version: version, deleted: deleted,
                                                removedDefaults: removedDefaults)
    return true
  }

  /// The launch entry point (DolphinCoreService): live Config, standard defaults.
  @objc(runAtLaunchWithFastmemAvailable:)
  static func runAtLaunch(fastmemAvailable: Bool) {
    runIfNeeded(defaults: .standard, config: BridgeSettingsRepairConfigStore(), fastmemAvailable: fastmemAvailable)
  }

  private static func shouldDelete(_ value: String, condition: Condition, fastmemAvailable: Bool) -> Bool {
    switch condition {
    case .always:
      return true
    case .whenTrue:
      return parseBool(value) == true
    case let .whenInt(values):
      return parseInt(value).map(values.contains) ?? false
    case .whenFalseWithFastmem:
      return fastmemAvailable && parseBool(value) == false
    }
  }

  // Parsers matching Dolphin's TryParse: bools are "true"/"false" in any case or "1"/"0".
  static func parseBool(_ value: String) -> Bool? {
    switch value.trimmingCharacters(in: .whitespaces).lowercased() {
    case "true", "1": return true
    case "false", "0": return false
    default: return nil
    }
  }

  static func parseInt(_ value: String) -> Int? {
    Int(value.trimmingCharacters(in: .whitespaces))
  }

  static func parseFloat(_ value: String) -> Float? {
    Float(value.trimmingCharacters(in: .whitespaces))
  }
}

/// The Base config layer as the repair sees it. Keys are "<system>.<section>.<key>".
protocol SettingsRepairConfigStore {
  /// Every key present in the Base layer, with its stored string.
  func baseSnapshot() -> [String: String]
  /// Deletes these keys from the Base layer; returns the ones deleted with their old values.
  func deleteBaseKeys(_ keys: [String]) -> [String: String]
  /// Writes the Base layer to disk.
  func save()
  /// What the config files on disk hold now, keyed like `baseSnapshot`.
  func savedBaseSnapshot() -> [String: String]
}

struct BridgeSettingsRepairConfigStore: SettingsRepairConfigStore {
  func baseSnapshot() -> [String: String] { DOLConfigBridge.baseLayerSnapshot() }
  func deleteBaseKeys(_ keys: [String]) -> [String: String] { DOLConfigBridge.deleteBaseLayerKeys(keys) }
  func save() { DOLConfigBridge.flushSettingsToDisk() }
  func savedBaseSnapshot() -> [String: String] { DOLConfigBridge.savedBaseConfigSnapshot() }
}
