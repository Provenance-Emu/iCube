// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import AVFoundation
import SwiftUI

/// Audio, on the menu engine. `sync()` reads Config and the live stream into the snapshot and writes nothing;
/// `apply(_:)` is the only writer.
struct ConfigAudioView: View {
  @State private var state = ConfigAudioState()

  var body: some View {
    SettingsLeafScreen(model: ConfigAudioModelBuilder.make(state: state, apply: apply), title: L("Audio"), sync: sync)
      .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in state.live = ConfigAudioSync.live() }
  }

  private func sync() {
    state = ConfigAudioSync.read()
  }

  private func apply(_ change: ConfigAudioChange) {
    ConfigAudioSync.apply(change, to: &state)
  }
}

/// The bridge calls behind the Audio screen and the in-game effects sheet, in one place so both agree.
enum ConfigAudioSync {
  static func read() -> ConfigAudioState {
    var s = ConfigAudioState()
    s.backends = DOLConfigBridge.audioBackends()
    s.backend = DOLConfigBridge.audioBackend()
    s.volume = DOLConfigBridge.audioVolume()
    s.surround = DOLConfigBridge.audioSurround()
    s.surroundQuality = DOLConfigBridge.audioSurroundQuality()
    s.spatial = DOLConfigBridge.audioSpatial()
    s.headTracking = DOLConfigBridge.audioSpatialHeadTracking()
    s.bufferMs = DOLConfigBridge.audioBufferSizeMs()
    s.fillGaps = DOLConfigBridge.audioFillGaps()
    s.preservePitch = DOLConfigBridge.audioPreservePitch()
    s.muteOnNoSpeedLimit = DOLConfigBridge.audioMuteOnDisabledSpeedLimit()
    s.obeyMuteSwitch = DOLConfigBridge.audioMuteSwitchObey()
    s.effects = effects()
    s.live = live()
    return s
  }

  static func effects() -> AudioEffectsState {
    var fx = AudioEffectsState()
    fx.echoEnabled = DOLConfigBridge.audioFXDelayEnabled()
    fx.echoMs = DOLConfigBridge.audioFXDelayMs()
    fx.echoFeedback = DOLConfigBridge.audioFXDelayFeedback()
    fx.eqEnabled = DOLConfigBridge.audioFXEQEnabled()
    fx.eqLowDb = DOLConfigBridge.audioFXEQLowDb()
    fx.eqMidDb = DOLConfigBridge.audioFXEQMidDb()
    fx.eqHighDb = DOLConfigBridge.audioFXEQHighDb()
    fx.crushEnabled = DOLConfigBridge.audioFXCrushEnabled()
    fx.crushBits = DOLConfigBridge.audioFXCrushBits()
    fx.crushDownsample = DOLConfigBridge.audioFXCrushDownsample()
    return fx
  }

  static func live() -> AudioLiveState {
    var l = AudioLiveState()
    l.routeDescription = AudioFXBridge.routeDescription()
    l.routeMaxChannels = AudioFXBridge.routeMaxOutputChannels()
    l.routeIsHeadphones = AudioFXBridge.routeIsHeadphones()
    l.outputMode = AudioFXBridge.outputModeName()
    l.microphoneSupported = AudioFXBridge.microphoneSupported()
    l.microphonePermission = AudioFXBridge.microphonePermission()
    return l
  }

  static func apply(_ change: ConfigAudioChange, to state: inout ConfigAudioState) {
    switch change {
    case .backend(let raw):
      guard raw != state.backend else { return }
      state.backend = raw; DOLConfigBridge.setAudioBackend(raw)
    case .volume(let v): state.volume = v; DOLConfigBridge.setAudioVolume(v)
    case .surround(let v): state.surround = v; DOLConfigBridge.setAudioSurround(v)
    case .surroundQuality(let v): state.surroundQuality = v; DOLConfigBridge.setAudioSurroundQuality(v)
    case .spatial(let v): state.spatial = v; DOLConfigBridge.setAudioSpatial(v)
    case .headTracking(let v): state.headTracking = v; DOLConfigBridge.setAudioSpatialHeadTracking(v)
    case .bufferMs(let v): state.bufferMs = v; DOLConfigBridge.setAudioBufferSizeMs(v)
    case .fillGaps(let v): state.fillGaps = v; DOLConfigBridge.setAudioFillGaps(v)
    case .preservePitch(let v): state.preservePitch = v; DOLConfigBridge.setAudioPreservePitch(v)
    case .muteOnNoSpeedLimit(let v): state.muteOnNoSpeedLimit = v; DOLConfigBridge.setAudioMuteOnDisabledSpeedLimit(v)
    case .obeyMuteSwitch(let v): state.obeyMuteSwitch = v; DOLConfigBridge.setAudioMuteSwitchObey(v)
    case .effect(let fx): apply(fx, to: &state.effects)
    case .requestMicrophoneAccess:
      AudioFXBridge.requestMicrophonePermission { _ in }
    case .openSystemSettings:
      #if os(iOS)
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
      }
      #endif
    }
  }

  static func apply(_ change: AudioEffectsChange, to fx: inout AudioEffectsState) {
    switch change {
    case .echoEnabled(let v): fx.echoEnabled = v; DOLConfigBridge.setAudioFXDelayEnabled(v)
    case .echoMs(let v): fx.echoMs = v; DOLConfigBridge.setAudioFXDelayMs(v)
    case .echoFeedback(let v): fx.echoFeedback = v; DOLConfigBridge.setAudioFXDelayFeedback(v)
    case .eqEnabled(let v): fx.eqEnabled = v; DOLConfigBridge.setAudioFXEQEnabled(v)
    case .eqLowDb(let v): fx.eqLowDb = v; DOLConfigBridge.setAudioFXEQLowDb(v)
    case .eqMidDb(let v): fx.eqMidDb = v; DOLConfigBridge.setAudioFXEQMidDb(v)
    case .eqHighDb(let v): fx.eqHighDb = v; DOLConfigBridge.setAudioFXEQHighDb(v)
    case .crushEnabled(let v): fx.crushEnabled = v; DOLConfigBridge.setAudioFXCrushEnabled(v)
    case .crushBits(let v): fx.crushBits = v; DOLConfigBridge.setAudioFXCrushBits(v)
    case .crushDownsample(let v): fx.crushDownsample = v; DOLConfigBridge.setAudioFXCrushDownsample(v)
    }
  }
}
