// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

/// The name this device shows to other devices: in Nearby (Continuity) and in
/// the DSU Bonjour advert. The system name by default; the user can override
/// it from the Nearby screen. The Objective-C side (`DSUServerBridge`) reads
/// the same `defaultsKey`.
enum ICubeDeviceName {
    static let defaultsKey = "icube_device_name"
    static let maxLength = 40

    /// The stored name, or `systemName` when none is stored or it is blank.
    static func current(defaults: UserDefaults = .standard,
                        systemName: String = UIDevice.current.name) -> String {
        let stored = defaults.string(forKey: defaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? systemName : stored
    }

    /// Stores `name` trimmed and capped at `maxLength` characters. `nil`, or a
    /// name that is blank after trimming, clears the override.
    static func set(_ name: String?, defaults: UserDefaults = .standard) {
        let trimmed = String((name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(trimmed, forKey: defaultsKey)
        }
    }
}
