// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Where Settings opens: a leaf, and optionally the row inside it to bring into view (a pause tile's long-press).
struct SettingsDeepLink: Hashable {
  let leafID: String
  var rowID: String?
}

/// The row a deep link asked for, handed to the first leaf `MenuScreen` that shows it, once. A reference type in the
/// environment so that screen can consume it: pushed sub-leaves and later sidebar picks inherit the same box and
/// find it empty, instead of jumping again.
final class SettingsRowTarget {
  private var rowID: String?

  init(rowID: String? = nil) {
    self.rowID = rowID
  }

  /// True until a screen has taken the row.
  var isPending: Bool { rowID != nil }

  /// The requested row when `ids` contains it, and from then on nil.
  func take(from ids: [String]) -> String? {
    guard let rowID, ids.contains(rowID) else { return nil }
    self.rowID = nil
    return rowID
  }
}

extension EnvironmentValues {
  /// Set by `SettingsRootView` for a deep link with a row; read by `MenuScreen`'s list renderers.
  @Entry var settingsRowTarget: SettingsRowTarget? = nil
}
