// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import GameController

public extension GCController {
  var supportsTouchpad: Bool {
    if #available(iOS 14.0, tvOS 14.0, *) {
      if extendedGamepad is GCDualSenseGamepad { return true }
      if let ds4 = extendedGamepad as? GCDualShockGamepad { return ds4.touchpadPrimary != nil }
    }
    return false
  }
}
