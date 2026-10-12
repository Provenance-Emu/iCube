// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// A coarse label derived from a cheat's name, the way iFly's CHT/FCD parsers
/// tag their bundled cheats. Dolphin's Gecko/AR sources (the bundled game ini
/// and codes.rc24.xyz) carry no category of their own, so the name is all
/// there is to go on. Cases are in display order; `classify` tries the more
/// specific ones first.
enum CheatCategory: String, CaseIterable, Hashable {
  case invincible, infinite, max, controls, display, debug, unlock, other

  var displayName: String {
    switch self {
    case .invincible: return L("Invincible")
    case .infinite: return L("Infinite")
    case .max: return L("Max")
    case .controls: return L("Controls")
    case .display: return L("Display")
    case .debug: return L("Debug")
    case .unlock: return L("Unlock")
    case .other: return L("Other")
    }
  }

  /// SF Symbol for a chip or badge.
  var icon: String {
    switch self {
    case .invincible: return "shield.fill"
    case .infinite: return "infinity"
    case .max: return "arrow.up.to.line"
    case .controls: return "gamecontroller.fill"
    case .display: return "display"
    case .debug: return "ladybug.fill"
    case .unlock: return "lock.open.fill"
    case .other: return "ellipsis.circle"
    }
  }

  private struct Rule {
    let category: CheatCategory
    /// Matched as substrings of the lowercased name (multi-word or stem matches).
    let phrases: [String]
    /// Matched as whole words only, so "max" never fires on "Climax".
    let words: [String]
  }

  /// Order matters: "Enable Debug Menu" is Debug, not Unlock; "Enable 16:9" is Display.
  private static let rules: [Rule] = [
    Rule(category: .invincible,
         phrases: ["invincib", "god mode", "no damage", "never die", "immortal", "invulnerab", "can't die", "cannot die"],
         words: ["invincible", "godmode"]),
    Rule(category: .infinite,
         phrases: ["infinite", "unlimited", "never decrease", "never run out", "never lose", "endless", "no cooldown", "never deplete"],
         words: ["inf", "∞"]),
    Rule(category: .max,
         phrases: ["maximum", "9999", "999 "],
         words: ["max", "999"]),
    Rule(category: .controls,
         phrases: ["classic controller", "nunchuk", "gamecube controller", "gc controller", "wii remote", "wiimote", "motion control",
                   "pointer", "sensitivity", "rumble", "button", "controller", "d-pad", "dpad", "analog stick"],
         words: ["controls", "control"]),
    Rule(category: .display,
         phrases: ["widescreen", "16:9", "16x9", "aspect", "frame rate", "framerate", "resolution", "bloom", "field of view",
                   "480p", "pal60", "progressive", "camera", "letterbox", "hud", "subtitles", "brightness", "depth of field",
                   "motion blur", "anti-alias", "vsync", "v-sync", "render"],
         words: ["fps", "60fps", "30fps", "60hz", "fov", "graphics", "screen"]),
    Rule(category: .debug,
         phrases: ["debug", "dev menu", "developer", "test mode", "test menu", "cheat menu"],
         words: ["menu"]),
    Rule(category: .unlock,
         phrases: ["unlock", "have all", "all characters", "all levels", "all stages", "all items", "all weapons", "all cars",
                   "all courses", "all tracks", "everything", "complete", "level select", "stage select", "skip", "enable",
                   "always have", "unlocked"],
         words: ["all"]),
  ]

  static func classify(name: String) -> CheatCategory {
    let lowered = name.lowercased()
    let words = Set(lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "∞" }).map(String.init))
    for rule in rules {
      if rule.phrases.contains(where: { lowered.contains($0) }) { return rule.category }
      if rule.words.contains(where: { words.contains($0) }) { return rule.category }
    }
    return .other
  }
}
