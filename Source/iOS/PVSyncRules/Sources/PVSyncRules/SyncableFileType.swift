// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// A category of file that iCube is willing to move off-device — to a sync
/// backend (CloudKit today; the content server, a shared iCloud Drive folder or
/// a nearby device later) or to a peer during a continuity handoff.
///
/// Every feature that moves user data classifies through this one type so
/// "what may leave the device" has exactly one answer. The category carries its
/// own policy traits (`isOptIn`, `maxFileSizeBytes`, `mergeKind`,
/// `propagatesDeletes`, `isLarge`) so adding a category is one `case` plus one
/// row in each switch, and nothing elsewhere has to learn about it.
///
/// Design spec: `docs/superpowers/specs/2026-10-11-icube-user-data-sync-design.md`.
public enum SyncableFileType: String, Codable, Sendable, CaseIterable {

    // MARK: Always on when sync is on

    /// `StateSaves/{GameID}.s{NN}` — a numbered save-state slot.
    case saveState
    /// `StateSaves/{GameID}.auto` — the resume-where-left-off state.
    case resumeState
    /// `StateSaves/*.json` — save-state metadata sidecar.
    case saveStateMetadata
    /// `StateSaves/*.png` — save-state thumbnail.
    case saveStateThumbnail
    /// `GC/**/MemoryCard*.raw`, `*.gci` — GameCube memory-card data.
    case gameCubeMemoryCard
    /// `Wii/title/*/*/data/**` — Wii NAND save data, plus `SYSCONF`.
    case wiiSave
    /// `GBA/Saves/**` — saves for Dolphin's integrated GBA.
    case gbaSave
    /// `Config/*.ini` — global emulator configuration, controller INIs included.
    case config
    /// `GameSettings/{GameID}.ini` — per-game settings.
    ///
    /// - Important: in iCube this one file also carries **cheats**. iFly keeps
    ///   the two apart; iCube cannot without splitting the INI, so anything
    ///   reasoning about "sync cheats" must reason about this case.
    case gameSettings
    /// `Profiles/game_profiles.json` — iCube's per-game profile store. Merged
    /// per game, never whole-file.
    case gameProfile
    /// `Profiles/touch_overlay_layout*.json` — the on-screen controller layout.
    case touchOverlayLayout
    /// `Profiles/library_state.json` — favorites, last played, launches and
    /// play time. Merged per field, never whole-file.
    case libraryState
    /// `Skins/selection.json` and `Skins/<identifier>/**` — installed
    /// controller skins and which one is picked.
    case skin

    // MARK: Opt-in, default off

    /// `GC/IPL.bin`, `GC/<region>/IPL.bin` — the user's own GameCube firmware
    /// dump. Opt-in: it is copyrighted firmware and the user decides whether
    /// their copy goes to their own private iCloud database.
    case firmware
    /// Installed Wii channels, WiiWare, Virtual Console and DLC: the title
    /// content and ticket for title types `00010001`, `00010004`, `00010005`,
    /// `00010008`, plus `Wii/shared1/**` which channels depend on. Opt-in.
    case wiiChannel
    /// Everything else in the Wii NAND: system menu, IOS, system titles and
    /// their tickets, `shared2` apart from `SYSCONF`, `meta`, `sys`. Opt-in,
    /// and implies `wiiChannel`.
    case wiiSystem

    // MARK: - Traits

    /// Off until the user turns the matching switch on. Everything else syncs
    /// whenever sync itself is on.
    public var isOptIn: Bool {
        switch self {
        case .firmware, .wiiChannel, .wiiSystem: return true
        default: return false
        }
    }

    /// Whether a file of this category is "large" for the purpose of the
    /// "large files over Wi-Fi only" switch. Deliberately the same set as
    /// `isOptIn`: the always-on categories are small enough to move on any
    /// connection, and splitting the two notions would be one more thing to
    /// explain in Settings.
    public var isLarge: Bool { isOptIn }

    /// Largest file of this category that may ever leave the device. Applied in
    /// addition to the path rules, never instead of them.
    public var maxFileSizeBytes: Int64 {
        switch self {
        case .firmware: return 4 * 1024 * 1024
        case .skin: return 32 * 1024 * 1024
        case .wiiChannel, .wiiSystem: return 256 * 1024 * 1024
        default: return SyncClassifier.maxFileSizeBytes
        }
    }

    /// How two differing copies of a file in this category are reconciled.
    public var mergeKind: SyncMergeKind {
        switch self {
        case .gameProfile, .libraryState: return .document
        default: return .wholeFile
        }
    }

    /// Whether deleting a file of this category on one device removes it on
    /// the others (through a tombstone). Merged documents are never deleted,
    /// so they never tombstone.
    public var propagatesDeletes: Bool { mergeKind == .wholeFile }

    /// Order in which to pull files during a continuity handoff or a first
    /// sync: smallest and most essential first, so a transfer that dies partway
    /// leaves the most usable payload behind. Lower sorts earlier. A total
    /// order — tests assert there are no ties.
    public var pullPriority: Int {
        switch self {
        case .saveStateMetadata: return 0
        case .gameSettings: return 1
        case .config: return 2
        case .saveState: return 3
        case .resumeState: return 4
        case .gameCubeMemoryCard: return 5
        case .wiiSave: return 6
        case .gbaSave: return 7
        case .libraryState: return 8
        case .gameProfile: return 9
        case .touchOverlayLayout: return 10
        case .skin: return 11
        case .firmware: return 12
        case .wiiChannel: return 13
        case .wiiSystem: return 14
        case .saveStateThumbnail: return 15
        }
    }

    /// Whether this category is required for the receiving device to boot the
    /// game at the handed-off point. Consumed by the continuity fallback table.
    public var isRequiredToResume: Bool {
        switch self {
        case .saveState, .resumeState: return true
        default: return false
        }
    }
}

/// How the sync engine reconciles two differing copies of one file.
public enum SyncMergeKind: String, Codable, Sendable {
    /// One copy wins (by timestamp, or the user decides). The default.
    case wholeFile
    /// The two copies are merged field by field by a `DocumentMerger`; neither
    /// side is ever discarded and no conflict is surfaced.
    case document
}
