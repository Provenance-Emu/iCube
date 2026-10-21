// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// One set of live controls shared by the paused pane and remote overlay.
enum PerformanceControlsModelBuilder {
  static func build(state: PerformanceControlsState, apply: @escaping (PerformanceControlChange) -> Void) -> MenuModel {
    let cpuOwner: PerformanceControlOverride = state.adaptiveClock ? .auto : state.cpuOverride
    let viOwner: PerformanceControlOverride = state.adaptiveClock ? .auto : state.viOverride
    let clocks = MenuSection(id: "performance-clocks", header: L("Clock Tuning"), items: [
      SettingsRow.toggle("performance-cpu-enabled", L("CPU Clock Override"), state.cpuEnabled,
        L("Apply your manual CPU clock percentage while playing."), enabled: cpuOwner == .none,
        badge: cpuOwner.badge, disabledReason: cpuOwner.disabledReason.map { L($0) }, set: { apply(.cpuEnabled($0)) }),
      percent("performance-cpu-percent", L("CPU Clock"), state.cpuPercent, state.cpuEnabled, cpuOwner,
        set: { apply(.cpuPercent($0)) }),
      SettingsRow.toggle("performance-vi-enabled", L("VI Frequency Override"), state.viEnabled,
        L("Apply your manual video interrupt frequency while playing."), enabled: viOwner == .none,
        badge: viOwner.badge, disabledReason: viOwner.disabledReason.map { L($0) }, set: { apply(.viEnabled($0)) }),
      percent("performance-vi-percent", L("VI Frequency"), state.viPercent, state.viEnabled, viOwner,
        set: { apply(.viPercent($0)) }),
      SettingsRow.toggle("performance-adaptive-clock", L("Adaptive Clock"), state.adaptiveClock,
        L("Automatically adjusts CPU and VI clocks for this run. Manual clock values are preserved."),
        set: { apply(.adaptiveClock($0)) }),
      SettingsRow.picker("performance-vi-skip", L("VI Skip"),
        [(L("Off"), PerformanceVISkipMode.off), (L("On"), .on), (L("Auto"), .auto)], state.viSkipMode,
        L("Choose whether to skip video interrupts. Auto follows the performance controller."),
        set: { apply(.viSkipMode($0)) }),
    ])
    let graphics = MenuSection(id: "performance-graphics", header: L("Graphics"), items: [
      SettingsRow.picker("performance-resolution", L("Internal Resolution"), resolutionOptions(maxScale: state.maxResolutionScale),
        state.resolutionScale, L("Fit Window chooses a scale for the window. Fixed scales remain unchanged during play."),
        enabled: state.scalingOverride == .none, badge: state.scalingOverride.badge,
        disabledReason: state.scalingDisabledReason.map { L($0) }, set: { apply(.resolutionScale($0)) }),
      SettingsRow.picker("performance-anisotropy", L("Anisotropic Filtering"), [1, 2, 4, 8, 16].map { ("\($0)x", $0) },
        state.anisotropy, L("Sharpens textures viewed at an angle. Higher values use more GPU."),
        set: { apply(.anisotropy($0)) }),
    ])
    var hudItems = [SettingsRow.toggle("performance-hud-enabled", L("Performance HUD"), state.hud.isEnabled,
      L("Show frame rate and speed, or turn off all performance statistics."), set: { apply(.hudEnabled($0)) })]
    hudItems += PerformanceHUDStatistic.allCases.map { statistic in
      SettingsRow.toggle("performance-hud-\(statistic.rawValue)", L(statistic.title), state.hud[keyPath: statistic.keyPath],
        L("Show this statistic over the game."), set: { apply(.hudStatistic(statistic, $0)) })
    }
    return MenuModel(sections: [clocks, graphics, MenuSection(id: "performance-hud", header: L("Display Overlays"), items: hudItems)])
  }

  static func resolutionOptions(maxScale: Int) -> [(String, Int)] {
    [(L("Fit Window"), 0), ("1x (\(L("Native")))", 1)]
      + stride(from: 2, through: max(1, maxScale), by: 1).map { ("\($0)x", $0) }
  }

  private static func percent(_ id: String, _ title: String, _ value: Int, _ enabled: Bool,
                              _ owner: PerformanceControlOverride, set: @escaping (Int) -> Void) -> MenuItem {
    SettingsRow.stepper(id, title, Double(value), range: 1...400, step: 1, format: { "\(Int($0))%" },
      L("Manual percentage of the original clock, from 1% to 400%."), enabled: enabled && owner == .none,
      badge: owner.badge, disabledReason: owner.disabledReason.map { L($0) } ?? L("Enable the clock override to adjust its percentage."),
      set: { if $0.isFinite { set(Int(min(400, max(1, $0)).rounded())) } })
  }
}
