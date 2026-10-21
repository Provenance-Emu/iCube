// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The Performance HUD tile: Dolphin's on-screen stats as one switch. On when any stat is drawn; switching it on draws
/// frame rate and speed, switching it off clears every stat. Long-press opens per-stat switches in the tvOS pause
/// submenu or the iOS Performance Controls panel; they also live in Settings > Graphics Advanced.
enum PerfHUDToggle {
  struct Flags: Equatable {
    var fps = false
    var vps = false
    var speed = false
    var graphs = false
    var overlayStats = false
    var vblank = false

    var isOn: Bool { fps || vps || speed || graphs || overlayStats || vblank }
  }

  /// What switching the HUD on draws.
  static let onFlags = Flags(fps: true, speed: true)

  static func flags(on: Bool) -> Flags { on ? onFlags : Flags() }

  static func read() -> Flags {
    Flags(fps: DOLConfigBridge.gfxShowFPS(), vps: DOLConfigBridge.gfxShowVPS(), speed: DOLConfigBridge.gfxShowSpeed(),
          graphs: DOLConfigBridge.gfxShowGraphs(), overlayStats: DOLConfigBridge.gfxOverlayStats(), vblank: DOLConfigBridge.gfxShowVTimes())
  }

  static var isOn: Bool { read().isOn }

  static func set(_ on: Bool) {
    let wanted = flags(on: on)
    DOLConfigBridge.setGfxShowFPS(wanted.fps)
    DOLConfigBridge.setGfxShowVPS(wanted.vps)
    DOLConfigBridge.setGfxShowSpeed(wanted.speed)
    DOLConfigBridge.setGfxShowGraphs(wanted.graphs)
    DOLConfigBridge.setGfxOverlayStats(wanted.overlayStats)
    DOLConfigBridge.setGfxShowVTimes(wanted.vblank)
  }
  enum Stat: String, CaseIterable {
    case fps, vps, speed, vblank, graphs, overlayStats

    var title: String {
      switch self {
      case .fps: return "FPS"
      case .vps: return "VPS"
      case .speed: return L("Speed")
      case .vblank: return "VBlank"
      case .graphs: return L("Perf Graph")
      case .overlayStats: return L("Overlay Stats")
      }
    }

    var keyPath: WritableKeyPath<Flags, Bool> {
      switch self {
      case .fps: return \.fps
      case .vps: return \.vps
      case .speed: return \.speed
      case .vblank: return \.vblank
      case .graphs: return \.graphs
      case .overlayStats: return \.overlayStats
      }
    }

    func set(_ on: Bool) {
      switch self {
      case .fps: DOLConfigBridge.setGfxShowFPS(on)
      case .vps: DOLConfigBridge.setGfxShowVPS(on)
      case .speed: DOLConfigBridge.setGfxShowSpeed(on)
      case .vblank: DOLConfigBridge.setGfxShowVTimes(on)
      case .graphs: DOLConfigBridge.setGfxShowGraphs(on)
      case .overlayStats: DOLConfigBridge.setGfxOverlayStats(on)
      }
    }
  }

}
