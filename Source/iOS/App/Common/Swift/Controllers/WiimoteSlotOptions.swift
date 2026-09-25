// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The per-Wii-Remote Extension / Sideways setters shared by
/// `ControllerSetupSections` and `RemapPlayerView`, so a change made on either
/// screen goes through exactly the same path. `DOLWiimoteBridge` itself posts
/// `DOLWiiOverlayLayoutChangedNotification` after each write, so the touch
/// overlay re-lays-out without any Swift-side re-post.
enum WiimoteSlotOptions {
  /// 0 None, 1 Nunchuk, 2 Classic — `WiimoteEmu::ExtensionNumber` order.
  static let extensionCount = 3

  static func selectedExtension(forWiimote indexOneBased: Int) -> Int {
    Int(DOLWiimoteBridge.selectedExtension(forWiimote: indexOneBased - 1))
  }

  static func isSideways(forWiimote indexOneBased: Int) -> Bool {
    DOLWiimoteBridge.isSideways(forWiimote: indexOneBased - 1)
  }

  static func setExtension(_ value: Int, forWiimote indexOneBased: Int) {
    DOLWiimoteBridge.setExtensionForWiimote(indexOneBased - 1, extension: value)
    // autoAssign: false — this is an explicit per-slot action, not a device
    // connect/disconnect. Running the full assignment engine here is exactly
    // the anti-pattern `ControllerManager.reconcile(autoAssign:)` documents:
    // toggling one Wiimote's extension must not re-decide every other port's
    // device binding.
    ControllerManager.shared.reconcile(autoAssign: false)
  }

  static func setSideways(_ enabled: Bool, forWiimote indexOneBased: Int) {
    DOLWiimoteBridge.setSidewaysForWiimote(indexOneBased - 1, enabled: enabled)
    ControllerManager.shared.reconcile(autoAssign: false)
  }

  static func extensionName(_ value: Int) -> String {
    switch value {
    case 1: return L("Nunchuk")
    case 2: return L("Classic")
    default: return L("None")
    }
  }
}
