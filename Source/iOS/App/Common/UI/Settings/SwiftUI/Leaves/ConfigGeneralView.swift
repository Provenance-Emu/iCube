// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// General, on the menu engine. `sync()` reads Config and UserDefaults into the snapshot and writes nothing;
/// `apply(_:)` and the Fallback Region seed are the only writers.
struct ConfigGeneralView: View {
  @State private var state = ConfigGeneralState()

  var body: some View {
    SettingsLeafScreen(model: ConfigGeneralModelBuilder.make(state: state, apply: apply), title: L("General"), sync: sync)
      .onAppear(perform: seedFallbackRegion)
      .onReceive(NotificationCenter.default.publisher(for: .DOLConfigChanged)) { _ in seedFallbackRegion() }
  }

  private func sync() {
    let defaults = UserDefaults.standard
    var s = ConfigGeneralState()
    s.dualCore = DOLConfigBridge.mainCpuThread()
    s.dspThread = DOLConfigBridge.mainDSPThread()
    s.cheats = DOLConfigBridge.mainEnableCheats()
    s.overrideRegion = DOLConfigBridge.mainOverrideRegionSettings()
    s.autoDiscChange = DOLConfigBridge.mainAutoDiscChange()
    s.fastDiscSpeed = DOLConfigBridge.mainFastDiscSpeed()
    s.resumeWhereLeftOff = defaults.bool(forKey: ConfigGeneralDefaultsKey.resumeWhereLeftOff)
    s.speedLimitPercent = DOLConfigBridge.mainEmulationSpeedPercent()
    s.fastForwardSpeedPercent = ConfigGeneralState.storedFastForward(defaults.object(forKey: ConfigGeneralDefaultsKey.fastForwardSpeedPercent) as? Int)
    s.fallbackRegion = ConfigGeneralState.displayedRegion(raw: DOLConfigBridge.mainFallbackRegion())
    state = s
  }

  /// The one write outside `apply`: Config holding the Error region is replaced with NTSC-U, on appear and on every Config change
  /// (a reset or game-INI load), as the old `syncFromConfig` did on each sync. The write re-posts the change once; the second
  /// pass sees a valid region, `fallbackRegionSeed` returns nil, and it stops. `sync()` itself only displays NTSC-U in that case.
  private func seedFallbackRegion() {
    if let region = ConfigGeneralState.fallbackRegionSeed(configRaw: DOLConfigBridge.mainFallbackRegion()) {
      DOLConfigBridge.setMainFallbackRegion(region.rawValue)
    }
  }

  private func apply(_ change: ConfigGeneralChange) {
    let defaults = UserDefaults.standard
    switch change {
    case .dualCore(let v): state.dualCore = v; DOLConfigBridge.setMainCpuThread(v)
    case .dspThread(let v): state.dspThread = v; DOLConfigBridge.setMainDSPThread(v)
    case .cheats(let v): state.cheats = v; DOLConfigBridge.setMainEnableCheats(v)
    case .overrideRegion(let v): state.overrideRegion = v; DOLConfigBridge.setMainOverrideRegionSettings(v)
    case .autoDiscChange(let v): state.autoDiscChange = v; DOLConfigBridge.setMainAutoDiscChange(v)
    case .fastDiscSpeed(let v): state.fastDiscSpeed = v; DOLConfigBridge.setMainFastDiscSpeed(v)
    case .resumeWhereLeftOff(let v): state.resumeWhereLeftOff = v; defaults.set(v, forKey: ConfigGeneralDefaultsKey.resumeWhereLeftOff)
    case .speedLimit(let v): state.speedLimitPercent = v; DOLConfigBridge.setMainEmulationSpeedPercent(v)
    case .fastForwardSpeed(let v): state.fastForwardSpeedPercent = v; defaults.set(v, forKey: ConfigGeneralDefaultsKey.fastForwardSpeedPercent)
    case .fallbackRegion(let v): state.fallbackRegion = v; DOLConfigBridge.setMainFallbackRegion(v.rawValue)
    }
  }
}
