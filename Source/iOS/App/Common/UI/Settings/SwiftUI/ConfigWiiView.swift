// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit
import CoreHaptics
import QuartzCore
import PVWebServer
import PVHelp
#if os(iOS)
import SafariServices
import AudioToolbox
#endif
#if canImport(GameController)
import GameController
#endif
#if os(iOS)
#endif
import Foundation

struct ConfigWiiView: View {
  @State private var pal60: Bool = false
  @State private var screensaver: Bool = false
  @State private var keyboard: Bool = false
  @State private var wiilink: Bool = false
  @State private var sdCard: Bool = false
  @State private var sdWrites: Bool = false
  @State private var sdFolderSync: Bool = false
  @State private var widescreen: Bool = false
  @State private var language: Int = 1
  @State private var soundMode: Int = 1
  @State private var sensorBarPos: Int = 0
  @State private var sensorBarSens: Int = 2
  @State private var speakerVol: Int = 4
  @State private var wiimoteRumble: Bool = true
  @State private var touchpadIRFollowWithoutClick: Bool = false

  var body: some View {
    List {
      Section(header: Text(L("Video")), footer: Text(L("These write to the emulated Wii's SYSCONF, so they affect Wii titles only and persist like a real Wii would."))) {
        settingsCaption(
          Toggle(L("Use PAL60 Mode (EuRGB60)"), isOn: $pal60.onSet { DOLConfigBridge.setSysconfPAL60($0) }),
          L("Lets PAL games output 60 Hz (EuRGB60) when supported."))
        /// Wii System Aspect Ratio (4:3 vs 16:9)
        settingsNavCaption(
          destination: WiiAspectRatioPicker(selectedWide: $widescreen.onSet { DOLConfigBridge.setSysconfWidescreen($0) }),
          L("Sets the console's 4:3 vs 16:9 flag, which many Wii games read to choose their own widescreen rendering.")
        ) {
          HStack { Text(L("Aspect Ratio")); Spacer(); Text(widescreen ? "16:9" : "4:3").foregroundStyle(.secondary) }
        }
      }

      Section(header: Text(L("General"))) {
        settingsCaption(
          Toggle(L("Enable Screen Saver"), isOn: $screensaver.onSet { DOLConfigBridge.setSysconfScreensaver($0) }),
          L("Controls the emulated Wii's idle dimming only. No effect on this device's battery or performance."))
        settingsNavCaption(
          destination: WiiLanguagePicker(selected: $language.onSet { DOLConfigBridge.setSysconfLanguage($0) }),
          L("The Wii's own menu language; games read it to pick their in-game language.")
        ) {
          HStack { Text(L("System Language")); Spacer(); Text(languageLabel(language)).foregroundStyle(.secondary) }
        }
        settingsNavCaption(
          destination: WiiAudioModePicker(selected: $soundMode.onSet { DOLConfigBridge.setSysconfSoundMode($0) }),
          L("The Wii's audio output mode (Mono/Stereo/Surround); games read it to choose their output.")
        ) {
          HStack { Text(L("Audio Settings")); Spacer(); Text(audioModeLabel(soundMode)).foregroundStyle(.secondary) }
        }
      }

      Section(header: Text(L("Wii Remotes"))) {
        settingsNavCaption(
          destination: WiiSensorBarPosPicker(selected: $sensorBarPos.onSet { DOLConfigBridge.setSysconfSensorBarPosition($0) }),
          L("Must match where the game thinks the sensor bar sits (Top/Bottom) or the pointer inverts. On iCube the pointer is touch-driven, so set it to the game's expectation.")
        ) {
          HStack { Text(L("Sensor Bar Position")); Spacer(); Text(posLabel(sensorBarPos)).foregroundStyle(.secondary) }
        }
        settingsCaption(
          HStack {
            Text(L("Sensor Bar Sensitivity"))
            Spacer()
#if os(tvOS)
            TVIntStepper(value: $sensorBarSens.onSet { DOLConfigBridge.setSysconfSensorBarSensitivity($0) }, range: 1 ... 5, step: 1)
#else
            Slider(value: $sensorBarSens.onSet { DOLConfigBridge.setSysconfSensorBarSensitivity($0) }.asDouble, in: 1 ... 5)
              .frame(width: 260)
#endif
          },
          L("Mirrors the real Wii's IR sensitivity slider."))
        settingsCaption(
          HStack {
            Text(L("Speaker Volume")); Spacer()
#if os(tvOS)
            TVIntStepper(value: $speakerVol.onSet { DOLConfigBridge.setSysconfSpeakerVolume($0) }, range: 0 ... 7, step: 1)
#else
            Slider(value: $speakerVol.onSet { DOLConfigBridge.setSysconfSpeakerVolume($0) }.asDouble, in: 0 ... 7)
              .frame(width: 260)
#endif
          },
          L("Mirrors the real Wii's Wii Remote speaker volume slider."))
        settingsCaption(
          Toggle(L("Rumble"), isOn: $wiimoteRumble.onSet { DOLConfigBridge.setSysconfWiimoteMotor($0) }),
          L("No physical effect on this device, but some games gate behavior on rumble being enabled."))
        settingsCaption(
          Toggle(L("Allow Touchpad IR Follow Without Click"), isOn: $touchpadIRFollowWithoutClick.onSet { UserDefaults.standard.set($0, forKey: "touchpad_ir_follow_without_click") }),
          L("Moves the IR pointer as your finger hovers/drags without needing a tap. Helps aiming in some games."))
      }

      Section(header: Text(L("USB / SD")), footer: Text(L("Emulated Wii peripherals. None of these affect emulation speed."))) {
        settingsCaption(
          Toggle(L("Emulate Skylander Portal"), isOn: Binding(get: { DOLConfigBridge.mainEmulateSkylanderPortal() }, set: { DOLConfigBridge.setMainEmulateSkylanderPortal($0) })),
          L("Exposes a virtual Skylanders portal to games that support it."))
        settingsCaption(
          Toggle(L("Connect USB Keyboard"), isOn: $keyboard.onSet { DOLConfigBridge.setMainWiiKeyboard($0) }),
          L("Presents a USB keyboard to games and the System Menu."))
        settingsCaption(
          Toggle(L("Enable WiiConnect24 via WiiLink"), isOn: $wiilink.onSet { DOLConfigBridge.setMainWiiWiiLinkEnable($0) }),
          L("Enables fan-revived WiiConnect24 online channels through WiiLink."))
        settingsCaption(
          Toggle(L("Insert SD Card"), isOn: $sdCard.onSet { DOLConfigBridge.setMainWiiSDCard($0) }),
          L("Exposes a virtual SD card to games and the System Menu."))
        settingsCaption(
          Toggle(L("Allow Writes to SD Card"), isOn: $sdWrites.onSet { DOLConfigBridge.setMainAllowSDWrites($0) }),
          L("Lets titles modify the virtual SD card. Off keeps it read-only."))
        settingsCaption(
          Toggle(L("Synchronize SD Card Folder on Start/Stop"), isOn: $sdFolderSync.onSet { DOLConfigBridge.setMainWiiSDCardEnableFolderSync($0) }),
          L("Mirrors a host folder to/from the card image when emulation starts and stops."))
      }
    }
    .navigationTitle(L("Wii"))
    .configSynced { syncWii() }
  }

  private func syncWii() {
    pal60 = DOLConfigBridge.sysconfPAL60()
    widescreen = DOLConfigBridge.sysconfWidescreen()
    screensaver = DOLConfigBridge.sysconfScreensaver()
    language = DOLConfigBridge.sysconfLanguage()
    soundMode = DOLConfigBridge.sysconfSoundMode()
    sensorBarPos = DOLConfigBridge.sysconfSensorBarPosition()
    sensorBarSens = DOLConfigBridge.sysconfSensorBarSensitivity()
    speakerVol = DOLConfigBridge.sysconfSpeakerVolume()
    wiimoteRumble = DOLConfigBridge.sysconfWiimoteMotor()
    touchpadIRFollowWithoutClick = UserDefaults.standard.bool(forKey: "touchpad_ir_follow_without_click")
    keyboard = DOLConfigBridge.mainWiiKeyboard()
    wiilink = DOLConfigBridge.mainWiiWiiLinkEnable()
    sdCard = DOLConfigBridge.mainWiiSDCard()
    sdWrites = DOLConfigBridge.mainAllowSDWrites()
    sdFolderSync = DOLConfigBridge.mainWiiSDCardEnableFolderSync()
  }

  private func posLabel(_ v: Int) -> String { v == 0 ? L("Bottom") : L("Top") }

  private func languageLabel(_ v: Int) -> String {
    switch v {
    case 0: return L("Japanese"); case 1: return L("English"); case 2: return L("German"); case 3: return L("French"); case 4: return L("Spanish"); case 5: return L("Italian"); case 6: return L("Dutch"); case 7: return L("Simplified Chinese"); case 8: return L("Traditional Chinese"); case 9: return L("Korean"); default: return L("Error")
    }
  }

  private func audioModeLabel(_ v: Int) -> String {
    switch v {
    case 0: return L("Mono"); case 1: return L("Stereo"); case 2: return L("Surround"); default: return L("Error")
    }
  }
}

private struct WiiLanguagePicker: View {
  @Binding var selected: Int
  private let options: [Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
  var body: some View {
    List {
      ForEach(options, id: \.self) { v in SettingsSelectRow(label: label(v), checked: v == selected) { selected = v; DOLConfigBridge.setSysconfLanguage(v) } }
    }
    .navigationTitle(L("System Language"))
  }
  private func label(_ v: Int) -> String {
    switch v {
    case 0: return L("Japanese"); case 1: return L("English"); case 2: return L("German"); case 3: return L("French"); case 4: return L("Spanish"); case 5: return L("Italian"); case 6: return L("Dutch"); case 7: return L("Simplified Chinese"); case 8: return L("Traditional Chinese"); case 9: return L("Korean"); default: return L("Error")
    }
  }
}

private struct WiiAudioModePicker: View {
  @Binding var selected: Int
  private let options: [Int] = [0, 1, 2]
  var body: some View {
    List {
      ForEach(options, id: \.self) { v in SettingsSelectRow(label: label(v), checked: v == selected) { selected = v; DOLConfigBridge.setSysconfSoundMode(v) } }
    }
    .navigationTitle(L("Audio Settings"))
  }
  private func label(_ v: Int) -> String { switch v { case 0: return L("Mono"); case 1: return L("Stereo"); case 2: return L("Surround"); default: return L("Error") } }
}

private struct WiiSensorBarPosPicker: View {
  @Binding var selected: Int
  var body: some View {
    List {
      SettingsSelectRow(label: L("Bottom"), checked: selected == 0) { selected = 0; DOLConfigBridge.setSysconfSensorBarPosition(0) }
      SettingsSelectRow(label: L("Top"), checked: selected == 1) { selected = 1; DOLConfigBridge.setSysconfSensorBarPosition(1) }
    }
    .navigationTitle(L("Sensor Bar Position"))
  }
}
/// Achievements config placeholder
private struct WiiAspectRatioPicker: View {
  @Binding var selectedWide: Bool
  var body: some View {
    List {
      SettingsSelectRow(label: "4:3", checked: selectedWide == false) { selectedWide = false; DOLConfigBridge.setSysconfWidescreen(false) }
      SettingsSelectRow(label: "16:9", checked: selectedWide == true) { selectedWide = true; DOLConfigBridge.setSysconfWidescreen(true) }
    }
    .navigationTitle(L("Aspect Ratio"))
  }
}
