// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Wii, on the menu engine. `sync()` reads Config into the snapshot and writes nothing; `apply(_:)` is the only writer.
struct ConfigWiiView: View {
  @State private var state = ConfigWiiState()

  var body: some View {
    SettingsLeafScreen(model: ConfigWiiModelBuilder.make(state: state, apply: apply), title: L("Wii"), sync: sync)
  }

  private func sync() {
    var s = ConfigWiiState()
    s.pal60 = DOLConfigBridge.sysconfPAL60()
    s.widescreen = DOLConfigBridge.sysconfWidescreen()
    s.screensaver = DOLConfigBridge.sysconfScreensaver()
    s.language = DOLConfigBridge.sysconfLanguage()
    s.soundMode = DOLConfigBridge.sysconfSoundMode()
    s.sensorBarPosition = DOLConfigBridge.sysconfSensorBarPosition()
    s.sensorBarSensitivity = DOLConfigBridge.sysconfSensorBarSensitivity()
    s.speakerVolume = DOLConfigBridge.sysconfSpeakerVolume()
    s.wiimoteRumble = DOLConfigBridge.sysconfWiimoteMotor()
    s.touchpadIRFollowWithoutClick = UserDefaults.standard.bool(forKey: ConfigWiiDefaultsKey.touchpadIRFollowWithoutClick)
    s.skylanderPortal = DOLConfigBridge.mainEmulateSkylanderPortal()
    s.keyboard = DOLConfigBridge.mainWiiKeyboard()
    s.wiilink = DOLConfigBridge.mainWiiWiiLinkEnable()
    s.sdCard = DOLConfigBridge.mainWiiSDCard()
    s.sdWrites = DOLConfigBridge.mainAllowSDWrites()
    s.sdFolderSync = DOLConfigBridge.mainWiiSDCardEnableFolderSync()
    state = s
  }

  private func apply(_ change: ConfigWiiChange) {
    switch change {
    case .pal60(let v): state.pal60 = v; DOLConfigBridge.setSysconfPAL60(v)
    case .widescreen(let v): state.widescreen = v; DOLConfigBridge.setSysconfWidescreen(v)
    case .screensaver(let v): state.screensaver = v; DOLConfigBridge.setSysconfScreensaver(v)
    case .language(let v): state.language = v; DOLConfigBridge.setSysconfLanguage(v)
    case .soundMode(let v): state.soundMode = v; DOLConfigBridge.setSysconfSoundMode(v)
    case .sensorBarPosition(let v): state.sensorBarPosition = v; DOLConfigBridge.setSysconfSensorBarPosition(v)
    case .sensorBarSensitivity(let v): state.sensorBarSensitivity = v; DOLConfigBridge.setSysconfSensorBarSensitivity(v)
    case .speakerVolume(let v): state.speakerVolume = v; DOLConfigBridge.setSysconfSpeakerVolume(v)
    case .wiimoteRumble(let v): state.wiimoteRumble = v; DOLConfigBridge.setSysconfWiimoteMotor(v)
    case .touchpadIRFollowWithoutClick(let v):
      state.touchpadIRFollowWithoutClick = v
      UserDefaults.standard.set(v, forKey: ConfigWiiDefaultsKey.touchpadIRFollowWithoutClick)
    case .skylanderPortal(let v): state.skylanderPortal = v; DOLConfigBridge.setMainEmulateSkylanderPortal(v)
    case .keyboard(let v): state.keyboard = v; DOLConfigBridge.setMainWiiKeyboard(v)
    case .wiilink(let v): state.wiilink = v; DOLConfigBridge.setMainWiiWiiLinkEnable(v)
    case .sdCard(let v): state.sdCard = v; DOLConfigBridge.setMainWiiSDCard(v)
    case .sdWrites(let v): state.sdWrites = v; DOLConfigBridge.setMainAllowSDWrites(v)
    case .sdFolderSync(let v): state.sdFolderSync = v; DOLConfigBridge.setMainWiiSDCardEnableFolderSync(v)
    }
  }
}
