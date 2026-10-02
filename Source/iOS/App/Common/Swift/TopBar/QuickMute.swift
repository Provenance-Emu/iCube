// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Mute as the pause menu and the top bar both do it: zero the master volume and remember the level it
/// had, so unmuting restores that level instead of guessing. One shared implementation (and one
/// UserDefaults key), otherwise the two buttons could disagree about whether the game is muted.
///
/// The volume goes through `DOLConfigBridge.setAudioVolume` (`SetBaseOrCurrent`), so a mute made here
/// persists into the next game until it is toggled back.
enum QuickMute {
  static let volumeBeforeMuteKey = "icube_pause_menu_volume_before_mute"
  /// Volume restored when nothing usable was remembered (never muted by us, or remembered 0).
  static let fallbackRestoreVolume = 100

  struct Transition: Equatable {
    let volume: Int
    /// The level to remember for the next unmute; nil leaves the stored value untouched.
    let rememberedVolume: Int?
    var isMuted: Bool { volume <= 0 }
  }

  /// Pure decision: what the volume becomes when the mute button is pressed.
  static func transition(currentVolume: Int, rememberedVolume: Int?) -> Transition {
    if currentVolume > 0 {
      return Transition(volume: 0, rememberedVolume: currentVolume)
    }
    let restore = rememberedVolume.flatMap { $0 > 0 ? $0 : nil } ?? fallbackRestoreVolume
    return Transition(volume: restore, rememberedVolume: nil)
  }

  static var isMuted: Bool { DOLConfigBridge.audioVolume() <= 0 }

  /// Flips mute and returns the new state.
  @discardableResult
  static func toggle(defaults: UserDefaults = .standard) -> Bool {
    let stored = defaults.object(forKey: volumeBeforeMuteKey) as? Int
    let next = transition(currentVolume: Int(DOLConfigBridge.audioVolume()), rememberedVolume: stored)
    if let remembered = next.rememberedVolume { defaults.set(remembered, forKey: volumeBeforeMuteKey) }
    DOLConfigBridge.setAudioVolume(next.volume)
    return next.isMuted
  }
}
