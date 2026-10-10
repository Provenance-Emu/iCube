// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// UserDefaults keys behind the General screen.
enum ConfigGeneralDefaultsKey {
  /// PauseMenuView reads this constant; TVEmulationBridge.mm keeps its own copy of the literal. A test pins the literal.
  static let fastForwardSpeedPercent = "fast_forward_speed_percent"
  /// Frontend-only: see SaveStateService.
  static let resumeWhereLeftOff = SaveStateService.resumeDefaultsKey
}

/// Snapshot of Config and UserDefaults for the General screen. Defaults match the old view's `@State` / `@AppStorage` defaults.
struct ConfigGeneralState: Equatable {
  var dualCore = false
  var dspThread = false
  var cheats = false
  var overrideRegion = false
  var autoDiscChange = false
  var fastDiscSpeed = false
  var resumeWhereLeftOff = false
  var speedLimitPercent = 0
  var fastForwardSpeedPercent = ConfigGeneralState.defaultFastForwardPercent
  var fallbackRegion = Region.ntscU

  static let normalSpeedPercent = 100
  static let defaultFastForwardPercent = 300
  /// 0 = Unlimited, then 10% steps up to 200%.
  static let speedLimitLadder = [0] + Array(stride(from: 10, through: 200, by: 10))
  static let fastForwardLadder = [0, 200, 300, 400, 500, 600, 800, 1000]

  static func speedLimitLabel(_ percent: Int) -> String {
    if percent == 0 { return L("Unlimited") }
    if percent == normalSpeedPercent { return String(format: "%d%% (%@)", percent, L("Normal Speed")) }
    return "\(percent)%"
  }

  /// A stored value off the ladder (the pause overlay can write one) shows as its raw percent.
  static func fastForwardLabel(_ percent: Int) -> String {
    if percent == 0 { return L("Unlimited") }
    if fastForwardLadder.contains(percent) { return "\(percent)% (\(percent / 100)x)" }
    return "\(percent)%"
  }

  static func speedLimitOptions(including stored: Int) -> [(String, Int)] {
    options(speedLimitLadder, including: stored).map { (speedLimitLabel($0), $0) }
  }

  static func fastForwardOptions(including stored: Int) -> [(String, Int)] {
    options(fastForwardLadder, including: stored).map { (fastForwardLabel($0), $0) }
  }

  /// `integer(forKey:)` would turn an unset key into 0 (Unlimited): only a truly unset key is 300.
  static func storedFastForward(_ stored: Int?) -> Int { stored ?? defaultFastForwardPercent }

  /// Display only: an unknown stored region shows as NTSC-U, as the old view did.
  static func displayedRegion(raw: Int) -> Region {
    let region = Region.from(raw: raw)
    return region == .unknown ? .ntscU : region
  }

  /// What the host's seed step writes: NTSC-U when Config holds the Error region, else nothing.
  static func fallbackRegionSeed(configRaw: Int) -> Region? {
    Region.from(raw: configRaw) == .unknown ? .ntscU : nil
  }

  /// The ladder, plus the stored value when it is not on it, so the row shows the raw value instead of a dash. Unlimited (0) stays first.
  private static func options(_ ladder: [Int], including value: Int) -> [Int] {
    ladder.contains(value) ? ladder : (ladder + [value]).sorted()
  }
}

/// One user edit. The host applies it to its snapshot AND to Config / UserDefaults; the builder only emits it.
enum ConfigGeneralChange: Equatable {
  case dualCore(Bool)
  case dspThread(Bool)
  case cheats(Bool)
  case overrideRegion(Bool)
  case autoDiscChange(Bool)
  case fastDiscSpeed(Bool)
  case resumeWhereLeftOff(Bool)
  case speedLimit(Int)
  case fastForwardSpeed(Int)
  case fallbackRegion(Region)
}
