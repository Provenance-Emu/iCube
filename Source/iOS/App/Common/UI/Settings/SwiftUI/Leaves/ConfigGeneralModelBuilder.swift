// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Pure: snapshot in, changes out (it cannot write). Descriptions are the captions the hand-built screen showed,
/// plus the help text its pickers carried (markup stripped).
enum ConfigGeneralModelBuilder {
  static func make(state: ConfigGeneralState, apply: @escaping (ConfigGeneralChange) -> Void) -> MenuModel {
    let basic = MenuSection(id: "basic-settings", header: L("Basic Settings"), items: [
      SettingsRow.toggle("dual-core", L("Enable Dual Core (speedup)"), state.dualCore,
                         L("Runs the emulated GPU on a separate thread from the emulated CPU (can deadlock some games on this interpreter)."),
                         set: { apply(.dualCore($0)) }),
      SettingsRow.toggle("dsp-thread", L("DSP Thread (speedup)"), state.dspThread,
                         L("Runs audio emulation on its own thread. Small speedup; safe to leave ON."),
                         set: { apply(.dspThread($0)) }),
      SettingsRow.toggle("cheats", L("Enable Cheats"), state.cheats,
                         L("Activates AR/Gecko cheat codes for the running game."),
                         set: { apply(.cheats($0)) }),
      SettingsRow.toggle("override-region", L("Override Region Mismatch"), state.overrideRegion,
                         L("Lets a game boot under a different region's settings. Can cause issues; leave OFF unless a game needs it."),
                         set: { apply(.overrideRegion($0)) }),
      SettingsRow.toggle("auto-disc-change", L("Auto Disc Change"), state.autoDiscChange,
                         L("Automatically swaps to the next disc for multi-disc games."),
                         set: { apply(.autoDiscChange($0)) }),
      SettingsRow.toggle("fast-disc-speed", L("Fast Disc Speed (speedup)"), state.fastDiscSpeed,
                         L("Removes emulated disc-read delays. Speeds up loading in most games but breaks a few that depend on real timing."),
                         set: { apply(.fastDiscSpeed($0)) }),
      SettingsRow.toggle("resume-where-left-off", L("Resume Where I Left Off"), state.resumeWhereLeftOff,
                         L("When you quit a game, your spot is auto-saved to a dedicated slot and reloaded the next time you launch that game. Never touches your numbered save slots."),
                         set: { apply(.resumeWhereLeftOff($0)) }),
    ])

    let speed = MenuSection(id: "speed", header: L("Speed"), items: [
      SettingsRow.cycle("speed-limit", L("Speed Limit"), ConfigGeneralState.speedLimitOptions(including: state.speedLimitPercent), state.speedLimitPercent,
                        described(L("Caps emulation speed as a percentage of real hardware. 100% is full speed; Unlimited runs as fast as the device allows. Lower it only to slow a game down deliberately."),
                                  L("If unsure, select 100%.")),
                        icon: "speedometer", set: { apply(.speedLimit($0)) }),
      SettingsRow.cycle("fast-forward-speed", L("Fast Forward Speed"), ConfigGeneralState.fastForwardOptions(including: state.fastForwardSpeedPercent), state.fastForwardSpeedPercent,
                        described(L("Speed used while the fast-forward button is held. Unlimited runs as fast as possible; the CPU-bound interpreter may not reach high multiples."),
                                  L("300% (3x) is recommended for most games.")),
                        icon: "forward.fill", set: { apply(.fastForwardSpeed($0)) }),
    ])

    let region = MenuSection(id: "fallback-region", items: [
      SettingsRow.cycle("fallback-region", L("Fallback Region"), Region.selectable.map { ($0.label, $0) }, state.fallbackRegion,
                        described(L("Region used for titles whose region can't be detected automatically."),
                                  L("This setting cannot be changed while emulation is active.")),
                        set: { apply(.fallbackRegion($0)) }),
    ])

    return MenuModel(sections: [basic, speed, region])
  }

  /// The row caption followed by the help text its picker used to carry.
  private static func described(_ caption: String, _ help: String) -> String { "\(caption) \(help)" }
}
