// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// GameCube settings. Unset language uses the core’s locale-derived default.
struct ConfigGameCubeView: View {
  @State private var state = ConfigGameCubeState()

  var body: some View {
    SettingsLeafScreen(model: ConfigGameCubeModelBuilder.make(state: state, apply: apply), title: L("GameCube"), sync: sync)
  }

  private func sync() {
    var s = ConfigGameCubeState()
    s.loadMainMenu = !DOLConfigBridge.mainSkipIPL()
    s.language = ConfigGameCubeState.displayedLanguage(stored: DOLConfigBridge.mainGCLanguage())
    s.slotBMicrophone = DOLConfigBridge.mainSlotBMicrophone()
    state = s
  }

  private func apply(_ change: ConfigGameCubeChange) {
    switch change {
    case .loadMainMenu(let v): state.loadMainMenu = v; DOLConfigBridge.setMainSkipIPL(!v)
    case .language(let v): state.language = v; DOLConfigBridge.setMainGCLanguage(v)
    case .slotBMicrophone(let v): state.slotBMicrophone = v; DOLConfigBridge.setMainSlotBMicrophone(v)
    }
  }
}
