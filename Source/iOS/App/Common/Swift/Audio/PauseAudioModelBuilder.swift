// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Plain snapshot for the pause menu's Audio pane — no bridge reads inside the builder.
struct PauseAudioState {
  /// A Wii title is running: the Wii's own sound mode and Remote speaker join the grid.
  var isWii = false
  var volume = 100
  var isMuted = false
  /// Raw Config backend name ("" = the compiled default) and (short label, raw) for every listed backend
  /// (`ConfigAudioState.shortBackendOptions`: the leaf's long labels overflow a tile badge).
  var backend = ""
  var backendOptions: [(String, String)] = []
  var surround = false
  var effects = AudioEffectsState()
  /// SYSCONF sound mode (0 Mono, 1 Stereo, 2 Surround) and Wii Remote speaker volume (0...7).
  var wiiSoundMode = 1
  var wiiSpeakerVolume = 4
}

/// Live bindings for the in-place tiles. Writing one applies immediately; the host rebuilds the model.
struct PauseAudioBindings {
  var volume: Binding<AnyHashable>
  var mute: Binding<Bool>
  var backend: Binding<AnyHashable> = .constant(AnyHashable(""))
  var surround: Binding<Bool> = .constant(false)
  var effectEnabled: (AudioEffectPage) -> Binding<Bool> = { _ in .constant(false) }
  var wiiSoundMode: Binding<AnyHashable> = .constant(AnyHashable(1))
  var wiiSpeakerVolume: Binding<AnyHashable> = .constant(AnyHashable(4))
}

struct PauseAudioActions {
  /// Opens one effect's parameter page (`.all` opens every effect's rows).
  var openEffect: (AudioEffectPage) -> Void
  /// Opens Settings on the Audio leaf.
  var openAudioSettings: () -> Void
  /// Opens Settings on the Wii console leaf (sound mode, speaker, Wii Speak).
  var openWiiSettings: () -> Void = {}
}

/// The pause menu's Audio pane: one grid of tiles in place of the old Mute and volume tiles on the main grid.
/// Volume and Mute are the prominent row; then Output (backend, surround, and the Wii's own sound rows for a
/// Wii title), Effects (one toggle per effect, long-press for its parameters) and the full settings.
/// Rendered by `TVPauseGridView` on tvOS and `MenuStyle.cards` on iOS, like the main grid.
enum PauseAudioModelBuilder {
  static let volumeID = "audio-volume"
  static let backendID = "audio-backend"
  static let surroundID = "audio-surround"
  static let soundModeID = "audio-wii-sound-mode"
  static let speakerVolumeID = "audio-wii-speaker"
  static let effectSettingsID = "audio-fx-settings"
  static let settingsID = "audio-settings"
  static func effectID(_ page: AudioEffectPage) -> String { "audio-fx-\(page.rawValue)" }

  static let speakerVolumeOptions: [(String, AnyHashable)] =
    [(L("Off"), AnyHashable(0))] + (1 ... 7).map { ("\($0)", AnyHashable($0)) }

  static func make(state: PauseAudioState, bindings: PauseAudioBindings, actions: PauseAudioActions) -> MenuModel {
    let level = MenuSection(id: "level", items: [
      MenuItem(id: volumeID, title: L("Volume"), icon: "speaker.wave.2", tint: .cyan,
               role: .cycle(options: PauseMenuModelBuilder.audioVolumeOptions(including: state.volume), selection: bindings.volume),
               description: L("Game volume. Tap to step, long-press to pick a level. The TV's own volume is on the remote.")),
      PauseMenuModelBuilder.muteItem(isMuted: state.isMuted, binding: bindings.mute),
    ])

    var output: [MenuItem] = [
      MenuItem(id: backendID, title: L("Backend"), icon: "hifispeaker", tint: .cyan,
               role: .cycle(options: state.backendOptions.map { ($0.0, AnyHashable($0.1)) }, selection: bindings.backend),
               description: L("CoreAudio has the lowest latency; AVAudioEngine adds spatial audio and plug-ins. Takes effect when a game starts.")),
      MenuItem(id: surroundID, title: L("Surround"), icon: "waveform.and.mic", tint: .cyan, role: .toggle(bindings.surround),
               description: L("Decode the game's Dolby Pro Logic II mix to 5.1 on a receiver, or spatial audio on headphones.")),
    ]
    if state.isWii {
      output.append(MenuItem(id: soundModeID, title: L("Wii Sound"), icon: "speaker.wave.3", tint: .cyan,
                             role: .cycle(options: ConfigWiiModelBuilder.soundModeOptions(including: state.wiiSoundMode).map { ($0.0, AnyHashable($0.1)) },
                                          selection: bindings.wiiSoundMode),
                             description: L("The console's own output mode, as set on a real Wii. Long-press for the Wii settings."),
                             longPress: .action(actions.openWiiSettings)))
      output.append(MenuItem(id: speakerVolumeID, title: L("Remote Speaker"), icon: "gamecontroller", tint: .cyan,
                             role: .cycle(options: speakerVolumeOptions, selection: bindings.wiiSpeakerVolume),
                             description: L("Volume of the Wii Remote's speaker, played through the TV. Long-press for the Wii settings."),
                             longPress: .action(actions.openWiiSettings)))
    }

    let effectTiles: [MenuItem] = [AudioEffectPage.echo, .equalizer, .bitcrusher].map { page in
      MenuItem(id: effectID(page), title: page.title, icon: page.icon, tint: .orange, role: .toggle(bindings.effectEnabled(page)),
               description: effectDescription(page), longPress: .action { actions.openEffect(page) })
    }
    let effects = MenuSection(id: "effects", header: L("Effects"), items: effectTiles + [
      MenuItem(id: effectSettingsID, title: L("Effect Settings"), icon: "slider.horizontal.3", tint: .orange,
               role: .action { actions.openEffect(.all) },
               badge: enabledEffectsBadge(state.effects),
               description: L("Every effect's parameters on one page.")),
    ])

    let more = MenuSection(id: "more", header: L("More"), items: [
      MenuItem(id: settingsID, title: L("All Audio Settings"), icon: "gearshape", tint: .gray, role: .action(actions.openAudioSettings),
               description: L("Buffer size, spatial audio, microphone and the rest, in Settings.")),
    ])

    return MenuModel(sections: [level, MenuSection(id: "output", header: L("Output"), items: output), effects, more])
  }

  /// "2 on" while effects are enabled, else nil: the Effect Settings tile's badge.
  static func enabledEffectsBadge(_ fx: AudioEffectsState) -> String? {
    let count = [AudioEffectPage.echo, .equalizer, .bitcrusher].filter { $0.isEnabled(in: fx) }.count
    return count > 0 ? String(format: L("%ld on"), count) : nil
  }

  private static func effectDescription(_ page: AudioEffectPage) -> String {
    switch page {
    case .echo: return L("A single repeat of the mix. Long-press for its time and feedback.")
    case .equalizer: return L("Bass, mids and treble. Long-press for the band gains.")
    case .bitcrusher: return L("Lo-fi: fewer bits and a lower sample rate. Long-press for its depth.")
    case .all: return L("Every effect's parameters on one page.")
    }
  }
}
