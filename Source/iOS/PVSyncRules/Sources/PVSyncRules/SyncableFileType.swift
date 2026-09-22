// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// A category of file that iCube is willing to move off-device — either to
/// CloudKit (WS-5) or to a nearby device during a continuity handoff (WS-4).
///
/// Both features share this type deliberately. "What may leave the device" is
/// one policy question, and having two answers to it is how a ROM eventually
/// ends up somewhere it should not be.
public enum SyncableFileType: String, Codable, Sendable, CaseIterable {
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
    /// `Wii/title/**/data/**` — Wii NAND save data, plus `Wii/sys/SYSCONF`.
    case wiiSave
    /// `Config/*.ini` — global emulator configuration.
    case config
    /// `GameSettings/{GameID}.ini` — per-game settings.
    ///
    /// - Important: in iCube this one file also carries **cheats**. iFly keeps
    ///   the two apart; iCube cannot without splitting the INI, so anything
    ///   reasoning about "sync cheats" must reason about this case.
    case gameSettings

    /// Order in which to pull files during a continuity handoff: smallest and
    /// most essential first, so a transfer that dies partway leaves the most
    /// usable payload behind. Lower sorts earlier.
    public var pullPriority: Int {
        switch self {
        case .saveStateMetadata: return 0
        case .gameSettings: return 1
        case .config: return 2
        case .saveState: return 3
        case .resumeState: return 4
        case .gameCubeMemoryCard: return 5
        case .wiiSave: return 6
        case .saveStateThumbnail: return 7
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
