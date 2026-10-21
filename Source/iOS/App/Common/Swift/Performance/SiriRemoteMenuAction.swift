// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

enum SiriRemoteMenuAction: String, CaseIterable {
  case pauseMenu, livePerformance
  static let defaultsKey = "tv_siri_remote_menu_action"

  static func stored(in defaults: UserDefaults = .standard) -> Self {
    defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .pauseMenu
  }

  func store(in defaults: UserDefaults = .standard) {
    defaults.set(rawValue, forKey: Self.defaultsKey)
  }

  var title: String {
    switch self {
    case .pauseMenu: return "Pause Menu"
    case .livePerformance: return "Live Performance"
    }
  }

  func opensLive(hasGameplayController: Bool, isPaused: Bool) -> Bool {
    self == .livePerformance && hasGameplayController && !isPaused
  }
}
