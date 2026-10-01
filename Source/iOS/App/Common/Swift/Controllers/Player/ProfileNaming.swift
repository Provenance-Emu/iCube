// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The names Save Profile As… writes (decision 10). A user profile named like a device-default
/// ("built-in") profile is used instead of the bundled one for every future first bind and every
/// Reset, because `loadProfile:` and `LoadTouchscreenProfile` search the user directory first (TVControllerMappingBridge.mm:432-433,
/// EmulationCoordinator.mm:1548-1563).
enum ProfileNaming {
  /// What `BridgeControllerConfigWriter.defaultProfileName(forQualifier:)` returns
  /// (BridgeControllerConfigWriter.swift:60-68); a test ties the two together.
  static let builtInNames = ["Physical Controller", "Touchscreen", "DSU"]

  /// Trimmed; a "/" would make a sub-path of the profile directory, so it becomes "-".
  static func sanitized(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
  }

  /// Case-insensitive: the profile directory is on a case-insensitive file system.
  static func isBuiltIn(_ name: String) -> Bool {
    builtInNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
  }

  /// The prompt's prefill: the bound pad's name, else the player title, never a built-in name.
  /// (Typing a built-in name is allowed; the view model asks first.)
  static func suggestion(padName: String?, playerTitle: String) -> String {
    if let padName, !padName.isEmpty, !isBuiltIn(padName) { return sanitized(padName) }
    return playerTitle
  }

  static func exists(_ name: String, in profiles: [String]) -> Bool {
    profiles.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
  }
}
