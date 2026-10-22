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

  /// A menu device, not a gameplay pad: the Siri Remote exposes a micro gamepad and no extended
  /// one. It never takes a GameCube port or Wii Remote slot (`ControllerStateStore.State
  /// .menuRemoteQualifiers`). A pad with neither profile (the Switch Online N64 pad, reached through
  /// `PhysicalProfileController`) is a gameplay pad.
  var isMenuRemote: Bool {
    microGamepad != nil && extendedGamepad == nil
  }
}
