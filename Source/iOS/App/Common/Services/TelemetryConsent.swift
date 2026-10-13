// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The user's "Share crash reports" choice (Settings → Privacy). Read before Sentry starts, which is before
/// DefaultPreferences.plist is registered, so the default (on) lives here, not in the plist.
enum TelemetryConsent {
  static let defaultsKey = "icube.telemetry.crashReports"

  static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: defaultsKey) as? Bool ?? true
  }

  static func set(_ on: Bool, defaults: UserDefaults = .standard) {
    defaults.set(on, forKey: defaultsKey)
  }
}
