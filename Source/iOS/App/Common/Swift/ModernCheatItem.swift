// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

// MARK: - Modern Cheat Item
internal enum ModernCheatItem {
  case gecko(TVGeckoCodeInfo)
  case actionReplay(TVActionReplayCodeInfo)

  var name: String {
    switch self {
    case .gecko(let code): return code.name
    case .actionReplay(let code): return code.name
    }
  }

  var isEnabled: Bool {
    switch self {
    case .gecko(let code): return code.enabled
    case .actionReplay(let code): return code.enabled
    }
  }

  var type: String {
    switch self {
    case .gecko: return "GECKO"
    case .actionReplay: return "AR"
    }
  }

  var typeColor: Color {
    switch self {
    case .gecko: return .blue
    case .actionReplay: return .orange
    }
  }
}
