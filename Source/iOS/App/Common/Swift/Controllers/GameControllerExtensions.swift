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

  /// A menu device, not a gameplay pad: a TV remote. It never takes a GameCube port or Wii Remote
  /// slot (`ControllerStateStore.State.menuRemoteQualifiers`).
  var isMenuRemote: Bool {
    Self.isMenuRemote(hasMicroGamepad: microGamepad != nil, hasExtendedGamepad: extendedGamepad != nil,
                      productCategory: productCategory)
  }

  /// Apple's remote product categories (GameController `GCProductCategory*Remote*`), as strings so the
  /// rule stays testable without hardware.
  static let menuRemoteProductCategories: Set<String> = [
    "Siri Remote (1st Generation)", "Siri Remote (2nd Generation)", "Control Center Remote",
    "Universal Electronics Remote", "Coalesced Remote",
  ]

  /// "Micro gamepad and no extended one" alone is not a remote: the Switch Online SNES pad
  /// (`Switch SNES Controller`) has exactly that shape, plus the legacy `gamepad` profile, and must
  /// stay a player. So a remote is that shape AND a remote product category (or any category naming
  /// a remote, for remotes Apple adds later).
  static func isMenuRemote(hasMicroGamepad: Bool, hasExtendedGamepad: Bool, productCategory: String) -> Bool {
    guard hasMicroGamepad, !hasExtendedGamepad else { return false }
    return menuRemoteProductCategories.contains(productCategory)
      || productCategory.range(of: "Remote", options: .caseInsensitive) != nil
  }
}
