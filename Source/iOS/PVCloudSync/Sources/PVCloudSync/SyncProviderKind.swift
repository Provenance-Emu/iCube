// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Where synced bytes go. One engine, several backends.
///
/// Only `iCloud` is constructed today. The others are named now so the index,
/// trash and settings can be keyed by backend from the start, and so the
/// mapping in the design spec (section 9) has something to attach to when the
/// content server and the shared iCloud Drive folder arrive.
public enum SyncProviderKind: String, Codable, CaseIterable, Sendable {
    /// CloudKit private database. Works on iOS and tvOS.
    case iCloud
    /// `Provenance-Emu/emulator-content-server` over the LAN or a relay.
    case contentServer
    /// A ubiquity container shared with Provenance and iFly. Not on tvOS.
    case iCloudDrive
    /// Another device on the local network (continuity).
    case nearby

    /// Short user-facing name.
    public var displayName: String {
        switch self {
        case .iCloud: return "iCloud"
        case .contentServer: return "Content Server"
        case .iCloudDrive: return "iCloud Drive"
        case .nearby: return "Nearby Device"
        }
    }

    /// Whether this backend can exist on tvOS, which has no Files app and no
    /// ubiquity container.
    public var isAvailableOnTV: Bool {
        switch self {
        case .iCloudDrive: return false
        default: return true
        }
    }
}
