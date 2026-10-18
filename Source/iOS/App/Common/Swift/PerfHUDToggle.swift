// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The Performance HUD tile: Dolphin's on-screen stats as one switch. On when any stat is drawn; switching it on draws
/// frame rate and speed, switching it off clears every stat. The per-stat switches stay in the Performance Controls
/// panel (the tile's long-press) and in Settings > Graphics Advanced.
enum PerfHUDToggle {
  struct Flags: Equatable {
    var fps = false
    var vps = false
    var speed = false
    var graphs = false
    var overlayStats = false

    var isOn: Bool { fps || vps || speed || graphs || overlayStats }
  }

  /// What switching the HUD on draws.
  static let onFlags = Flags(fps: true, speed: true)

  static func flags(on: Bool) -> Flags { on ? onFlags : Flags() }

  static func read() -> Flags {
    Flags(fps: DOLConfigBridge.gfxShowFPS(), vps: DOLConfigBridge.gfxShowVPS(), speed: DOLConfigBridge.gfxShowSpeed(),
          graphs: DOLConfigBridge.gfxShowGraphs(), overlayStats: DOLConfigBridge.gfxOverlayStats())
  }

  static var isOn: Bool { read().isOn }

  static func set(_ on: Bool) {
    let wanted = flags(on: on)
    DOLConfigBridge.setGfxShowFPS(wanted.fps)
    DOLConfigBridge.setGfxShowVPS(wanted.vps)
    DOLConfigBridge.setGfxShowSpeed(wanted.speed)
    DOLConfigBridge.setGfxShowGraphs(wanted.graphs)
    DOLConfigBridge.setGfxOverlayStats(wanted.overlayStats)
  }
}
