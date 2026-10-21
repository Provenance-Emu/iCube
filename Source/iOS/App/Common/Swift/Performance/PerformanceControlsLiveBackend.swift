// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

extension PerformanceControlsController {
  /// The app backend is isolated from the pure state/controller so host tests never impersonate a bridge.
  static func live() -> PerformanceControlsController {
    PerformanceControlsController(read: readLiveState, apply: applyLiveChange,
      sessionIdentifier: { TVEmulationBridge.currentSessionIdentifier() })
  }

  private static func readLiveState() -> PerformanceControlsState {
    var snapshot = PerformanceControlsState()
    // These three manual controls MUST read Base, never resolved CurrentRun/game values.
    snapshot.cpuEnabled = DOLConfigBridge.mainOverclockEnableBase()
    snapshot.cpuPercent = DOLConfigBridge.mainOverclockPercentBase()
    snapshot.viEnabled = DOLConfigBridge.mainViOverclockEnableBase()
    snapshot.viPercent = DOLConfigBridge.mainViOverclockPercentBase()
    snapshot.resolutionScale = DOLConfigBridge.gfxEfbScaleBase()
    snapshot.cpuOverride = provenance(DOLConfigBridge.overclockOverride())
    snapshot.viOverride = provenance(DOLConfigBridge.viOverclockOverride())
    snapshot.scalingOverride = provenance(DOLConfigBridge.efbScaleOverride())
    snapshot.maxResolutionScale = max(1, DOLConfigBridge.gfxEfbMaxScale())
    snapshot.anisotropy = DOLConfigBridge.gfxEnhanceAnisotropySamples()
    snapshot.adaptiveClock = UserDefaults.standard.bool(forKey: "adaptive_clock_enable")
    snapshot.viSkipMode = PerformanceVISkipMode(rawValue: DOLConfigBridge.gfxHackViSkipMode()) ?? .off
    snapshot.hud = PerformanceHUDState(
      fps: DOLConfigBridge.gfxShowFPS(), vps: DOLConfigBridge.gfxShowVPS(),
      speed: DOLConfigBridge.gfxShowSpeed(), vblank: DOLConfigBridge.gfxShowVTimes(),
      graphs: DOLConfigBridge.gfxShowGraphs(), overlayStats: DOLConfigBridge.gfxOverlayStats())
    return snapshot
  }

  private static func provenance(_ value: DOLConfigOverride) -> PerformanceControlOverride {
    switch value {
    case .none: return .none
    case .game: return .game
    default: return .auto
    }
  }

  private static func applyLiveChange(_ change: PerformanceControlChange) {
    switch change {
    case .cpuEnabled(let value): DOLConfigBridge.setMainOverclockEnable(value)
    case .cpuPercent(let value): DOLConfigBridge.setMainOverclockPercent(value)
    case .viEnabled(let value): DOLConfigBridge.setMainViOverclockEnable(value)
    case .viPercent(let value): DOLConfigBridge.setMainViOverclockPercent(value)
    case .resolutionScale(let value): DOLConfigBridge.setGfxEfbScale(value)
    case .anisotropy(let value): DOLConfigBridge.setGfxEnhanceAnisotropySamples(value)
    case .adaptiveClock(let value): EmulationCoordinator.shared().setAdaptiveClockEnabled(value)
    case .viSkipMode(let value): DOLConfigBridge.setGfxHackViSkipMode(value.rawValue)
    case .hudEnabled(let value): PerfHUDToggle.set(value)
    case .hudStatistic(let statistic, let value):
      switch statistic {
      case .fps: DOLConfigBridge.setGfxShowFPS(value)
      case .vps: DOLConfigBridge.setGfxShowVPS(value)
      case .speed: DOLConfigBridge.setGfxShowSpeed(value)
      case .vblank: DOLConfigBridge.setGfxShowVTimes(value)
      case .graphs: DOLConfigBridge.setGfxShowGraphs(value)
      case .overlayStats: DOLConfigBridge.setGfxOverlayStats(value)
      }
    }
  }
}
