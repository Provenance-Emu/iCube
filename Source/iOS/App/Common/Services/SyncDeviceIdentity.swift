// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// This install's stable identifier for sync records and per-device counters.
///
/// Preferred over `identifierForVendor`, which changes when the last app from a
/// vendor is deleted — that would orphan the "which device wrote this" field on
/// every record and split the per-device play counters in
/// `library_state.json`. Shared by `CloudSyncCoordinator` and
/// `LibraryStateStore` so they agree on who "this device" is.
enum SyncDeviceIdentity {
    private static let key = "icube.cloudSync.deviceIdentifier"

    static func deviceIdentifier(in defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: key)
        return fresh
    }
}
