// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Pure: snapshot in, changes out (it cannot write). Descriptions are the captions the hand-built screen showed.
enum ConfigWiiModelBuilder {
  /// SYSCONF language indices, the Wii's own order.
  static func languageOptions(including value: Int) -> [(String, Int)] {
    withStored(value, in: [
      (L("Japanese"), 0), (L("English"), 1), (L("German"), 2), (L("French"), 3), (L("Spanish"), 4),
      (L("Italian"), 5), (L("Dutch"), 6), (L("Simplified Chinese"), 7), (L("Traditional Chinese"), 8), (L("Korean"), 9),
    ])
  }

  static func soundModeOptions(including value: Int) -> [(String, Int)] {
    withStored(value, in: [(L("Mono"), 0), (L("Stereo"), 1), (L("Surround"), 2)])
  }

  static func sensorBarPositionOptions(including value: Int) -> [(String, Int)] {
    withStored(value, in: [(L("Bottom"), 0), (L("Top"), 1)])
  }

  /// A stored value no option names is added (as the old pickers' "Error" label) so the row never shows a dash.
  private static func withStored(_ value: Int, in options: [(String, Int)]) -> [(String, Int)] {
    options.contains(where: { $0.1 == value }) ? options : options + [(L("Error"), value)]
  }

  private static func number(_ value: Double) -> String { "\(Int(value))" }

  static func make(state: ConfigWiiState, apply: @escaping (ConfigWiiChange) -> Void) -> MenuModel {
    let video = MenuSection(
      id: "video", header: L("Video"),
      footer: L("These write to the emulated Wii's SYSCONF, so they affect Wii titles only and persist like a real Wii would."),
      items: [
        SettingsRow.toggle("pal60", L("Use PAL60 Mode (EuRGB60)"), state.pal60,
                           L("Lets PAL games output 60 Hz (EuRGB60) when supported."),
                           set: { apply(.pal60($0)) }),
        SettingsRow.cycle("aspect-ratio", L("Aspect Ratio"), [("4:3", false), ("16:9", true)], state.widescreen,
                          L("Sets the console's 4:3 vs 16:9 flag, which many Wii games read to choose their own widescreen rendering."),
                          set: { apply(.widescreen($0)) }),
      ])

    let general = MenuSection(id: "general", header: L("General"), items: [
      SettingsRow.toggle("screensaver", L("Enable Screen Saver"), state.screensaver,
                         L("Controls the emulated Wii's idle dimming only. No effect on this device's battery or performance."),
                         set: { apply(.screensaver($0)) }),
      SettingsRow.cycle("language", L("System Language"), languageOptions(including: state.language), state.language,
                        L("The Wii's own menu language; games read it to pick their in-game language."),
                        set: { apply(.language($0)) }),
      SettingsRow.cycle("sound-mode", L("Audio Settings"), soundModeOptions(including: state.soundMode), state.soundMode,
                        L("The Wii's audio output mode (Mono/Stereo/Surround); games read it to choose their output."),
                        set: { apply(.soundMode($0)) }),
    ])

    let remotes = MenuSection(id: "wii-remotes", header: L("Wii Remotes"), items: [
      SettingsRow.cycle("sensor-bar-position", L("Sensor Bar Position"), sensorBarPositionOptions(including: state.sensorBarPosition), state.sensorBarPosition,
                        L("Must match where the game thinks the sensor bar sits (Top/Bottom) or the pointer inverts. On iCube the pointer is touch-driven, so set it to the game's expectation."),
                        set: { apply(.sensorBarPosition($0)) }),
      SettingsRow.stepper("sensor-bar-sensitivity", L("Sensor Bar Sensitivity"), Double(state.sensorBarSensitivity),
                          range: ConfigWiiLimits.sensorBarSensitivity, step: 1, format: number,
                          L("Mirrors the real Wii's IR sensitivity slider."),
                          set: { apply(.sensorBarSensitivity(Int($0))) }),
      SettingsRow.stepper("speaker-volume", L("Speaker Volume"), Double(state.speakerVolume),
                          range: ConfigWiiLimits.speakerVolume, step: 1, format: number,
                          L("Mirrors the real Wii's Wii Remote speaker volume slider."),
                          set: { apply(.speakerVolume(Int($0))) }),
      SettingsRow.toggle("rumble", L("Rumble"), state.wiimoteRumble,
                         L("No physical effect on this device, but some games gate behavior on rumble being enabled."),
                         set: { apply(.wiimoteRumble($0)) }),
      SettingsRow.toggle("touchpad-ir-follow", L("Allow Touchpad IR Follow Without Click"), state.touchpadIRFollowWithoutClick,
                         L("Moves the IR pointer as your finger hovers/drags without needing a tap. Helps aiming in some games."),
                         set: { apply(.touchpadIRFollowWithoutClick($0)) }),
    ])

    let peripherals = MenuSection(
      id: "usb-sd", header: L("USB / SD"),
      footer: L("Emulated Wii peripherals. None of these affect emulation speed."),
      items: [
        SettingsRow.toggle("skylander-portal", L("Emulate Skylander Portal"), state.skylanderPortal,
                           L("Exposes a virtual Skylanders portal to games that support it."),
                           set: { apply(.skylanderPortal($0)) }),
        SettingsRow.toggle("usb-keyboard", L("Connect USB Keyboard"), state.keyboard,
                           L("Presents a USB keyboard to games and the System Menu."),
                           set: { apply(.keyboard($0)) }),
        SettingsRow.toggle("wiilink", L("Enable WiiConnect24 via WiiLink"), state.wiilink,
                           L("Enables fan-revived WiiConnect24 online channels through WiiLink."),
                           set: { apply(.wiilink($0)) }),
        SettingsRow.toggle("sd-folder-sync", L("Synchronize SD Card Folder on Start/Stop"), state.sdFolderSync,
                           L("Mirrors a host folder to/from the card image when emulation starts and stops."),
                           set: { apply(.sdFolderSync($0)) }),
      ])

    return MenuModel(sections: [video, general, remotes, peripherals])
  }
}
