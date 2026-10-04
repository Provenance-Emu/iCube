// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// How the emulated Wii Remote's pointer is driven. Raw values are `MAIN_TOUCH_PAD_IR_MODE`'s.
/// The core has no "off" value: 0 means the gyro drives it and the touch pad is idle.
enum PointerMode: Int, CaseIterable, Identifiable {
  case gyro = 0
  case touchFollow = 1
  case touchDrag = 2

  var id: Int { rawValue }

  var title: String {
    switch self {
    case .gyro: return L("Gyro")
    case .touchFollow: return L("Touch – Follow")
    case .touchDrag: return L("Touch – Drag")
    }
  }

  var systemImage: String {
    switch self {
    case .gyro: return "gyroscope"
    case .touchFollow: return "hand.point.up"
    case .touchDrag: return "hand.draw"
    }
  }
}

/// The one place the pointer mode changes. It used to be set directly from nine call sites
/// across the top bar, Settings, Advanced Motion, Motion Debug, the tvOS game properties and the
/// DSU controller, each with its own labels, and only the top bar updated the live pad.
///
/// Main-actor isolated: the only observer of `.DOLPointerModeDidChange` (EmulationScreen) writes
/// SwiftUI state, and `NotificationCenter` delivers on the posting thread.
@MainActor
final class PointerModeController {
  static let shared = PointerModeController(
    read: { Int(DOLConfigBridge.mainTouchPadIRMode()) },
    write: { DOLConfigBridge.setMainTouchPadIRMode($0) },
    writeCurrentRun: { DOLConfigBridge.setCurrentRunMainTouchPadIRMode($0) },
    notificationCenter: .default,
    isGameOverride: { DOLConfigBridge.isMainTouchPadIRModeGameOverride() })

  private let read: () -> Int
  private let write: (Int) -> Void
  private let writeCurrentRun: (Int) -> Void
  private let notificationCenter: NotificationCenter
  private let isGameOverride: () -> Bool

  init(
    read: @escaping () -> Int,
    write: @escaping (Int) -> Void,
    writeCurrentRun: @escaping (Int) -> Void,
    notificationCenter: NotificationCenter,
    isGameOverride: @escaping () -> Bool = { false }
  ) {
    self.read = read
    self.write = write
    self.writeCurrentRun = writeCurrentRun
    self.notificationCenter = notificationCenter
    self.isGameOverride = isGameOverride
  }

  /// The active value. `DOLConfigBridge.mainTouchPadIRMode()` is `Config::Get`, so a per-game
  /// CurrentRun override is what this reports while its title runs.
  var mode: PointerMode { PointerMode(rawValue: read()) ?? .touchFollow }

  /// The running title has its own pointer mode (Game Settings or a game INI): a change made now
  /// lasts for this game only. The player screen's Pointer row and the top bar say so.
  var isThisGameOnly: Bool { isGameOverride() }

  /// The user's choice. Without a per-game value it is the global setting (Base) and outlives the
  /// game; with one it can only replace that value, in CurrentRun, until the game ends. It used to
  /// land in CurrentRun whenever any layer had the key, and vanish at game end unannounced.
  func set(_ mode: PointerMode) {
    if isGameOverride() {
      writeCurrentRun(mode.rawValue)
    } else {
      write(mode.rawValue)
    }
    notifyChanged()
  }

  /// For call sites that hold the config's raw integer.
  func set(rawValue: Int) {
    set(PointerMode(rawValue: rawValue) ?? .touchFollow)
  }

  /// A per-game override (`GameProfiles`). Written to the CurrentRun layer so it ends with the
  /// title instead of becoming the global setting.
  func setCurrentRun(_ mode: PointerMode) {
    writeCurrentRun(mode.rawValue)
    notifyChanged()
  }

  func setCurrentRun(rawValue: Int) {
    setCurrentRun(PointerMode(rawValue: rawValue) ?? .touchFollow)
  }

  private func notifyChanged() {
    notificationCenter.post(name: .DOLPointerModeDidChange, object: nil)
  }
}
