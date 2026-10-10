// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Gain, deadzone and smoothing for the on-screen sticks and triggers. The keys keep their old
/// `dsu_` names; physical controllers and motion are never scaled. The player screen and
/// the DSU controller both push this one screen.
/// `sync()` reads UserDefaults into the snapshot and writes nothing; `apply(_:)` is the only writer.
struct AnalogStickSettingsView: View {
  @State private var state = AnalogStickState()

  var body: some View {
    SettingsLeafScreen(model: AnalogStickModelBuilder.make(state: state, apply: apply), title: L("On-Screen Stick Feel"), sync: sync)
  }

  private func sync() {
    let defaults = UserDefaults.standard
    var s = AnalogStickState()
    s.gain = AnalogStickState.stored(defaults.object(forKey: AnalogStickKey.gain), default: AnalogStickState.defaultGain)
    s.deadzone = AnalogStickState.stored(defaults.object(forKey: AnalogStickKey.deadzone), default: AnalogStickState.defaultDeadzone)
    s.smoothing = AnalogStickState.stored(defaults.object(forKey: AnalogStickKey.smoothing), default: AnalogStickState.defaultSmoothing)
    state = s
  }

  private func apply(_ change: AnalogStickChange) {
    let defaults = UserDefaults.standard
    switch change {
    case .gain(let v):
      state.gain = v
      defaults.set(v, forKey: AnalogStickKey.gain)
    case .deadzone(let v):
      state.deadzone = v
      defaults.set(v, forKey: AnalogStickKey.deadzone)
    case .smoothing(let v):
      state.smoothing = v
      defaults.set(v, forKey: AnalogStickKey.smoothing)
    }
  }
}
