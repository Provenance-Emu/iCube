// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Ownership of the effective running value. The stored values below always describe Base.
enum PerformanceControlOverride: Equatable {
  case none, game, auto

  var badge: String? {
    switch self {
    case .none: return nil
    case .game: return "Game"
    case .auto: return "Auto"
    }
  }

  var disabledReason: String? {
    switch self {
    case .none: return nil
    case .game: return "Controlled by the active game configuration."
    case .auto: return "Controlled automatically. Turn off the automatic controller to edit this setting."
    }
  }
}

enum PerformanceVISkipMode: Int, CaseIterable {
  case off = 0, on = 1, auto = 2
}

enum PerformanceHUDStatistic: String, CaseIterable {
  case fps, vps, speed, vblank, graphs, overlayStats

  var title: String {
    switch self {
    case .fps: return "FPS"
    case .vps: return "VPS"
    case .speed: return "Speed"
    case .vblank: return "VBlank"
    case .graphs: return "Perf Graph"
    case .overlayStats: return "Overlay Stats"
    }
  }

  var keyPath: WritableKeyPath<PerformanceHUDState, Bool> {
    switch self {
    case .fps: return \.fps
    case .vps: return \.vps
    case .speed: return \.speed
    case .vblank: return \.vblank
    case .graphs: return \.graphs
    case .overlayStats: return \.overlayStats
    }
  }
}

struct PerformanceHUDState: Equatable {
  var fps = false
  var vps = false
  var speed = false
  var vblank = false
  var graphs = false
  var overlayStats = false

  var isEnabled: Bool { fps || vps || speed || vblank || graphs || overlayStats }
}

struct PerformanceControlsState: Equatable {
  var cpuEnabled = false
  var cpuPercent = 100
  var cpuOverride: PerformanceControlOverride = .none
  var viEnabled = false
  var viPercent = 100
  var viOverride: PerformanceControlOverride = .none
  var resolutionScale = 1
  var maxResolutionScale = 1
  var scalingOverride: PerformanceControlOverride = .none
  var anisotropy = 1
  var adaptiveClock = false
  var viSkipMode: PerformanceVISkipMode = .off
  var hud = PerformanceHUDState()

  var cpuDisabledReason: String? { cpuOverride.disabledReason }
  var viDisabledReason: String? { viOverride.disabledReason }
  var scalingDisabledReason: String? { scalingOverride.disabledReason }
}

enum PerformanceControlChange: Equatable {
  case cpuEnabled(Bool), cpuPercent(Int)
  case viEnabled(Bool), viPercent(Int)
  case resolutionScale(Int), anisotropy(Int)
  case adaptiveClock(Bool), viSkipMode(PerformanceVISkipMode)
  case hudEnabled(Bool), hudStatistic(PerformanceHUDStatistic, Bool)
}
