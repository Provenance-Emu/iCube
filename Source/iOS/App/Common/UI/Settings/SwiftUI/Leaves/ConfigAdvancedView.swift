// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Advanced, on the menu engine. `sync()` reads Config into the snapshot and writes nothing; `apply(_:)` is the only writer.
struct ConfigAdvancedView: View {
  @State private var state = ConfigAdvancedState()

  var body: some View {
    SettingsLeafScreen(model: ConfigAdvancedModelBuilder.make(state: state, apply: apply), title: L("Advanced"), sync: sync)
  }

  private func sync() {
    var s = ConfigAdvancedState()
    s.memOverride = DOLConfigBridge.mainRamOverrideEnable()
    s.mem1MB = DOLConfigBridge.mainMem1SizeMB()
    s.mem2MB = DOLConfigBridge.mainMem2SizeMB()
    s.rtcEnabled = DOLConfigBridge.mainCustomRtcEnable()
    s.rtcDate = Date(timeIntervalSince1970: TimeInterval(DOLConfigBridge.mainCustomRtcValue()))
    state = s
  }

  private func apply(_ change: ConfigAdvancedChange) {
    switch change {
    case .memOverride(let v): state.memOverride = v; DOLConfigBridge.setMainRamOverrideEnable(v)
    case .mem1MB(let v): state.mem1MB = v; DOLConfigBridge.setMainMem1SizeMB(v)
    case .mem2MB(let v): state.mem2MB = v; DOLConfigBridge.setMainMem2SizeMB(v)
    case .rtcEnabled(let v): state.rtcEnabled = v; DOLConfigBridge.setMainCustomRtcEnable(v)
    case .rtcDate(let v): state.rtcDate = v; DOLConfigBridge.setMainCustomRtcValue(Int(v.timeIntervalSince1970))
    }
  }
}
