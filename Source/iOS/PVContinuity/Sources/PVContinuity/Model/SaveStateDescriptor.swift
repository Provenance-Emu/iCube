// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The save state a handoff hands off.
///
/// ## The stem rule
///
/// `stem` is the filename stem Dolphin itself used when it wrote the state —
/// `SConfig::GetInstance().GetGameID()`, surfaced through
/// `TVEmulationBridge.stateFilePathForSlot:` / `autoStateFilePath`, which mirror
/// `Core/State.cpp MakeStateFilename` (`{StateSavesDir}{GameID}.s{NN}`).
///
/// **The receiving device must use this stem verbatim and must never re-derive
/// it.** Not from the ROM's basename, not from the display title, not from its
/// own lookup of the disc header. The stem is what binds a state file to a game
/// in Dolphin's on-disk layout; a state written to a re-derived stem is a file
/// the emulator will never find, and the failure is silent — the user gets
/// "handoff succeeded" and then an empty save-state list.
///
/// The receiving device *does* own the directory: the state lands in its own
/// `StateSaves/`, which is what `relativePath` expresses.
public struct SaveStateDescriptor: Codable, Hashable, Sendable {
    /// Numbered slot, or nil for the dedicated resume state (`{stem}.auto`).
    public var slot: Int?
    /// The core-provided filename stem. Used verbatim. See the type doc.
    public var stem: String
    /// User-directory-relative path, e.g. `StateSaves/GALE01.s01`.
    public var relativePath: String
    public var sha256: String
    public var size: Int64
    /// Relative path of the `.png` thumbnail sibling, when one exists.
    public var thumbnailRelativePath: String?
    /// Relative path of the `.json` metadata sidecar, when one exists.
    public var metadataRelativePath: String?

    public init(
        slot: Int?,
        stem: String,
        relativePath: String,
        sha256: String,
        size: Int64,
        thumbnailRelativePath: String? = nil,
        metadataRelativePath: String? = nil
    ) {
        self.slot = slot
        self.stem = stem
        self.relativePath = relativePath
        self.sha256 = sha256
        self.size = size
        self.thumbnailRelativePath = thumbnailRelativePath
        self.metadataRelativePath = metadataRelativePath
    }

    /// True for the `{stem}.auto` resume state rather than a numbered slot.
    public var isResumeState: Bool { slot == nil }

    /// The state as a transferable file entry.
    public var fileDescriptor: FileDescriptor {
        FileDescriptor(
            kind: isResumeState ? .resumeState : .saveState,
            relativePath: relativePath,
            sha256: sha256,
            size: size,
            required: true
        )
    }

    // MARK: - Filename construction

    /// The directory, relative to the User directory, that Dolphin writes save
    /// states into (`File::GetUserPath(D_STATESAVES_IDX)`).
    public static let stateSavesDirectory = "StateSaves"

    /// `{stem}.s{NN}`, or `{stem}.auto` when `slot` is nil.
    ///
    /// Only ever called with a stem that came from the core. This helper exists
    /// so the `%02d` formatting is written once — it is not a licence to
    /// synthesise a stem.
    public static func fileName(stem: String, slot: Int?) -> String {
        guard let slot else { return "\(stem).auto" }
        return String(format: "%@.s%02d", stem, slot)
    }

    /// User-directory-relative path for a state, built from a core-provided
    /// stem. See `fileName(stem:slot:)`.
    public static func relativePath(stem: String, slot: Int?) -> String {
        "\(stateSavesDirectory)/\(fileName(stem: stem, slot: slot))"
    }
}
