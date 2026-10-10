// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Audio, on the menu engine. `sync()` reads Config into the snapshot and writes nothing; `apply(_:)` is the only writer.
struct ConfigAudioView: View {
  @State private var state = ConfigAudioState()
  /// A backend waiting for the user to confirm (AVAudioEngine only).
  @State private var pendingBackend: String?

  var body: some View {
    SettingsLeafScreen(model: ConfigAudioModelBuilder.make(state: state, apply: apply), title: L("Audio"), sync: sync)
      .alert(L("Enable AVAudioEngine?"), isPresented: Binding(get: { pendingBackend != nil }, set: { if !$0 { pendingBackend = nil } })) {
        Button(L("Enable")) {
          let raw = pendingBackend
          pendingBackend = nil
          if let raw { commitBackend(raw) }
        }
        Button(L("Cancel"), role: .cancel) { pendingBackend = nil }
      } message: {
        Text(L("AVAudioEngine is in development and not recommended for general usage yet. Are you sure?"))
      }
  }

  private func sync() {
    var s = ConfigAudioState()
    s.backends = DOLConfigBridge.audioBackends()
    s.backend = DOLConfigBridge.audioBackend()
    s.volume = DOLConfigBridge.audioVolume()
    s.stretch = DOLConfigBridge.audioStretch()
    s.stretchLatencyMs = DOLConfigBridge.audioStretchLatencyMs()
    s.muteOnNoSpeedLimit = DOLConfigBridge.audioMuteOnDisabledSpeedLimit()
    s.obeyMuteSwitch = DOLConfigBridge.audioMuteSwitchObey()
    state = s
  }

  private func apply(_ change: ConfigAudioChange) {
    switch change {
    case .backend(let raw):
      if ConfigAudioState.needsConfirmation(choosing: raw) { pendingBackend = raw } else { commitBackend(raw) }
    case .volume(let v): state.volume = v; DOLConfigBridge.setAudioVolume(v)
    case .stretch(let v): state.stretch = v; DOLConfigBridge.setAudioStretch(v)
    case .stretchLatencyMs(let v): state.stretchLatencyMs = v; DOLConfigBridge.setAudioStretchLatencyMs(v)
    case .muteOnNoSpeedLimit(let v): state.muteOnNoSpeedLimit = v; DOLConfigBridge.setAudioMuteOnDisabledSpeedLimit(v)
    case .obeyMuteSwitch(let v): state.obeyMuteSwitch = v; DOLConfigBridge.setAudioMuteSwitchObey(v)
    }
  }

  private func commitBackend(_ raw: String) {
    state.backend = raw
    DOLConfigBridge.setAudioBackend(raw)
  }
}
