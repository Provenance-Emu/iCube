// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The user's sync switches. Pure value type, persisted by the app, read by the
/// scanner (skip what is off), the planner (ignore remote files in an off
/// category) and the coordinator (hold large transfers for Wi-Fi).
///
/// The classifier never reads this. "What is this file" and "does the user
/// want it synced right now" are separate questions, and keeping them apart is
/// what lets a record written by a device with different switches still land
/// in the right category on this one.
public struct SyncPolicy: Codable, Equatable, Sendable {

    /// Sync the user's GameCube IPL dump.
    public var firmwareEnabled: Bool
    /// Sync installed Wii channels, WiiWare, Virtual Console and DLC.
    public var wiiChannelsEnabled: Bool
    /// Sync the whole Wii NAND. Implies `wiiChannelsEnabled`.
    public var fullWiiNANDEnabled: Bool
    /// Hold opt-in (large) categories until the network is neither expensive
    /// nor constrained. Always-on categories are small and move regardless.
    public var largeFilesOverWiFiOnly: Bool

    public init(
        firmwareEnabled: Bool = false,
        wiiChannelsEnabled: Bool = false,
        fullWiiNANDEnabled: Bool = false,
        largeFilesOverWiFiOnly: Bool = true
    ) {
        self.firmwareEnabled = firmwareEnabled
        self.wiiChannelsEnabled = wiiChannelsEnabled
        self.fullWiiNANDEnabled = fullWiiNANDEnabled
        self.largeFilesOverWiFiOnly = largeFilesOverWiFiOnly
    }

    /// Everything off, Wi-Fi rule on. What a fresh install gets.
    public static let `default` = SyncPolicy()

    /// Channels are part of the NAND, so turning the NAND on turns them on.
    public var effectiveWiiChannelsEnabled: Bool {
        wiiChannelsEnabled || fullWiiNANDEnabled
    }

    /// Whether files of this category may sync under these switches.
    public func allows(_ type: SyncableFileType) -> Bool {
        switch type {
        case .firmware: return firmwareEnabled
        case .wiiChannel: return effectiveWiiChannelsEnabled
        case .wiiSystem: return fullWiiNANDEnabled
        default: return true
        }
    }

    /// Whether a transfer of this category must wait for an unconstrained
    /// network.
    public func requiresUnconstrainedNetwork(for type: SyncableFileType) -> Bool {
        largeFilesOverWiFiOnly && type.isLarge
    }

    /// The categories these switches currently allow.
    public var allowedTypes: Set<SyncableFileType> {
        Set(SyncableFileType.allCases.filter(allows))
    }
}
