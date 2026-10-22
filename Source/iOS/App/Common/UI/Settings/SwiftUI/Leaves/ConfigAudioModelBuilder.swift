// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Pure: snapshot in, changes out (it cannot write).
enum ConfigAudioModelBuilder {
  static let pluginFooter = L("Audio Unit plug-ins installed on this device, applied after the built-in effects. Their settings are saved with the chain.")
  static let effectsFooter = L("Built-in effects run on both backends and on Apple TV. They apply to the whole mix, including 5.1 output.")
  static let surroundFooter = L("GameCube and Wii games mix surround as Dolby Pro Logic II inside their stereo output. Decoding it gives real 5.1 on an HDMI receiver, or a head-tracked sound field on headphones with the AVAudioEngine backend. Most accurate with DSP LLE.")

  static func make(state: ConfigAudioState, apply: @escaping (ConfigAudioChange) -> Void) -> MenuModel {
    let output = MenuSection(id: "output", header: L("Output"), items: [
      SettingsRow.picker("backend", L("Audio Backend"), state.backendOptions, state.backend,
                        L("CoreAudio drives the speaker directly with the lowest latency. AVAudioEngine adds spatial audio on headphones and Audio Unit plug-ins. Both play 5.1 on a six-channel route. Takes effect when a game starts."),
                        set: { apply(.backend($0)) }),
      SettingsRow.stepper("volume", L("Volume"), Double(state.volume), range: ConfigAudioLimits.volume, step: 1,
                          format: { "\(Int($0))%" },
                          L("Output level of the emulated console. The pause menu's Mute badge reflects this value."),
                          set: { apply(.volume(Int($0))) }),
    ])

    let surround = MenuSection(id: "surround", header: L("Surround & Spatial"), footer: surroundFooter, items: [
      SettingsRow.toggle("surround", L("Surround Sound"), state.surround,
                         L("Decodes the game's Dolby Pro Logic II mix to 5.1. On a stereo speaker route the mix stays stereo."),
                         set: { apply(.surround($0)) }),
      SettingsRow.picker("surround-quality", L("Decoder Quality"), ConfigAudioState.surroundQualityOptions, state.surroundQuality,
                         L("Block size of the surround decoder. Higher separates channels better and adds a little latency; Lowest is cheapest on the CPU."),
                         enabled: state.surround, disabledReason: L("Enable Dolby Pro Logic II decoding first."), set: { apply(.surroundQuality($0)) }),
      SettingsRow.toggle("spatial", L("Spatial Audio on Headphones"), state.spatial,
                         L("Renders the decoded 5.1 field binaurally on wired or Bluetooth headphones, AirPods included. AVAudioEngine backend with Surround Sound on."),
                         enabled: state.spatialRowsEnabled, disabledReason: L("Select AVAudioEngine and enable Dolby Pro Logic II decoding first."), set: { apply(.spatial($0)) }),
      SettingsRow.toggle("head-tracking", L("Head Tracking"), state.headTracking,
                         L("Keeps the sound field anchored to the screen as you turn your head, on headphones that report motion. Uses the system tracker on iOS 18 and tvOS 18."),
                         enabled: state.headTrackingRowEnabled, disabledReason: L("Select AVAudioEngine and enable Dolby Pro Logic II decoding and Spatial Audio first."), set: { apply(.headTracking($0)) }),
      SettingsRow.caption("output-caption", state.outputCaption),
    ])

    let timing = MenuSection(id: "timing", header: L("Timing"), items: [
      SettingsRow.stepper("buffer", L("Audio Buffer Size"), Double(state.bufferMs), range: ConfigAudioLimits.bufferMs, step: 1,
                          format: milliseconds,
                          L("How much mixed audio is kept ahead of the speaker. Lower is more responsive; higher survives frame-time spikes without crackling. 80 ms is a good default on iPhone."),
                          set: { apply(.bufferMs(Int($0))) }),
      SettingsRow.toggle("fill-gaps", L("Fill Audio Gaps"), state.fillGaps,
                         L("Repeats the last sound instead of going silent when the game runs slower than the speaker. Off gives crackles that make slowdown audible."),
                         set: { apply(.fillGaps($0)) }),
      SettingsRow.toggle("preserve-pitch", L("Preserve Pitch"), state.preservePitch,
                         L("Keeps music at its normal pitch when the emulation speed is not 100%, at the cost of some CPU. Off lets audio speed up and slow down with the game."),
                         set: { apply(.preservePitch($0)) }),
    ])

    var miscItems = [
      SettingsRow.toggle("mute-on-no-speed-limit", L("Mute When Disabling Speed Limit"), state.muteOnNoSpeedLimit,
                         L("Silences audio while the speed limit is off (fast-forward), when it would otherwise play sped up."),
                         set: { apply(.muteOnNoSpeedLimit($0)) }),
    ]
    #if os(iOS)
    miscItems.append(SettingsRow.toggle("obey-mute-switch", L("Use Mute Hardware Switch"), state.obeyMuteSwitch,
                                        L("Follows the device's silent switch: game audio is muted while it is on. Applies immediately."),
                                        set: { apply(.obeyMuteSwitch($0)) }))
    #endif
    let misc = MenuSection(id: "misc", header: L("Misc. Controls"), items: miscItems)

    return MenuModel(sections: [output, surround] + effectsSections(state, apply: apply) + [timing, misc] + microphoneSections(state, apply: apply))
  }

  /// The effects alone, for the in-game Audio Effects sheet.
  static func effectsModel(state: ConfigAudioState, apply: @escaping (ConfigAudioChange) -> Void) -> MenuModel {
    MenuModel(sections: effectsSections(state, apply: apply))
  }

  /// One effect's rows (its toggle, then its parameters), for the pause menu's per-effect page. `.all` is
  /// `effectsModel` without the plug-in chain. The rows are the leaf's own, so ids, wording and the
  /// disabled-until-enabled rule stay identical to Settings.
  static func effectPageModel(_ page: AudioEffectPage, state: ConfigAudioState, apply: @escaping (ConfigAudioChange) -> Void) -> MenuModel {
    guard let effects = effectsSections(state, apply: apply).first(where: { $0.id == "effects" }) else { return MenuModel(sections: []) }
    let wanted = page.rowIDs
    let items = wanted.isEmpty ? effects.items : effects.items.filter { wanted.contains($0.id) }
    return MenuModel(sections: [MenuSection(id: "effects", footer: page == .all ? effectsFooter : nil, items: items)],
                     focusRequest: page.toggleRowID)
  }

  static func effectsSections(_ state: ConfigAudioState, apply: @escaping (ConfigAudioChange) -> Void) -> [MenuSection] {
    let fx = state.effects
    let effects = MenuSection(id: "effects", header: L("Effects"), footer: effectsFooter, items: [
      SettingsRow.toggle("echo", L("Echo"), fx.echoEnabled,
                         L("A single repeat of the mix, blended in at 30%."),
                         set: { apply(.effect(.echoEnabled($0))) }),
      SettingsRow.stepper("echo-time", L("Echo Time"), Double(fx.echoMs), range: ConfigAudioLimits.echoMs, step: 10,
                          format: milliseconds, L("Delay before the repeat."),
                          enabled: fx.echoEnabled, disabledReason: L("Enable Echo first."), set: { apply(.effect(.echoMs(Int($0)))) }),
      SettingsRow.stepper("echo-feedback", L("Echo Feedback"), fx.echoFeedback, range: ConfigAudioLimits.echoFeedback, step: 0.05,
                          format: percent, L("How much of each repeat feeds the next one. Higher trails longer."),
                          enabled: fx.echoEnabled, disabledReason: L("Enable Echo first."), set: { apply(.effect(.echoFeedback($0))) }),
      SettingsRow.toggle("eq", L("Equalizer"), fx.eqEnabled,
                         L("Three bands: bass shelf at 150 Hz, mids at 1 kHz, treble shelf at 6 kHz."),
                         set: { apply(.effect(.eqEnabled($0))) }),
      SettingsRow.stepper("eq-low", L("Bass"), fx.eqLowDb, range: ConfigAudioLimits.eqDb, step: 1, format: decibels,
                          L("Gain of the bass shelf."), enabled: fx.eqEnabled, disabledReason: L("Enable Equalizer first."), set: { apply(.effect(.eqLowDb($0))) }),
      SettingsRow.stepper("eq-mid", L("Mids"), fx.eqMidDb, range: ConfigAudioLimits.eqDb, step: 1, format: decibels,
                          L("Gain of the mid band."), enabled: fx.eqEnabled, disabledReason: L("Enable Equalizer first."), set: { apply(.effect(.eqMidDb($0))) }),
      SettingsRow.stepper("eq-high", L("Treble"), fx.eqHighDb, range: ConfigAudioLimits.eqDb, step: 1, format: decibels,
                          L("Gain of the treble shelf."), enabled: fx.eqEnabled, disabledReason: L("Enable Equalizer first."), set: { apply(.effect(.eqHighDb($0))) }),
      SettingsRow.toggle("bitcrusher", L("Bitcrusher"), fx.crushEnabled,
                         L("Lo-fi: fewer bits per sample and a lower effective sample rate."),
                         set: { apply(.effect(.crushEnabled($0))) }),
      SettingsRow.stepper("crush-bits", L("Bit Depth"), Double(fx.crushBits), range: ConfigAudioLimits.crushBits, step: 1,
                          format: { "\(Int($0))" }, L("Bits kept per sample. 16 is transparent."),
                          enabled: fx.crushEnabled, disabledReason: L("Enable Bitcrusher first."), set: { apply(.effect(.crushBits(Int($0)))) }),
      SettingsRow.stepper("crush-downsample", L("Downsample"), Double(fx.crushDownsample), range: ConfigAudioLimits.crushDownsample, step: 1,
                          format: { "\(Int($0))x" }, L("Holds each sample this many times. 1 keeps the full rate."),
                          enabled: fx.crushEnabled, disabledReason: L("Enable Bitcrusher first."), set: { apply(.effect(.crushDownsample(Int($0)))) }),
    ])
    var sections = [effects]
    #if os(iOS)
    if state.isAVAudioEngine {
      let title = L("Audio Unit Plug-ins")
      sections.append(MenuSection(id: "plugins", header: title, footer: pluginFooter, items: [
        SettingsRow.custom("plugin-chain", title, AnyView(VStack { FXChainEditor() }), pluginFooter),
      ]))
    }
    #endif
    return sections
  }

  private static func microphoneSections(_ state: ConfigAudioState, apply: @escaping (ConfigAudioChange) -> Void) -> [MenuSection] {
    let footer = L("Enable the GameCube Microphone under GameCube and Wii Speak under Wii. iCube asks for microphone access the first time a game opens one.")
    let items: [MenuItem]
    switch state.microphoneAccess {
    case .unsupported:
      items = [SettingsRow.caption("microphone-unsupported", L("No microphone is available to apps on this device."))]
    case .ask:
      items = [SettingsRow.action("microphone-request", L("Allow Microphone Access"),
                                  L("Shows the system prompt now instead of the first time a game opens the microphone."),
                                  icon: "mic", run: { apply(.requestMicrophoneAccess) })]
    case .denied:
      items = [SettingsRow.action("microphone-settings", L("Microphone Access Denied"),
                                  L("Turn the microphone on for iCube in Settings to use the GameCube Microphone or Wii Speak."),
                                  icon: "mic.slash", run: { apply(.openSystemSettings) })]
    case .granted:
      items = [SettingsRow.caption("microphone-granted", L("Microphone access granted."))]
    }
    return [MenuSection(id: "microphone", header: L("Microphone"), footer: footer, items: items)]
  }

  private static func milliseconds(_ value: Double) -> String { String(format: L("%1$ld ms"), Int(value)) }
  private static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
  private static func decibels(_ value: Double) -> String { String(format: "%+.0f dB", value) }
}
