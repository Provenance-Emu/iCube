// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The single source of truth for which files may leave the device.
///
/// Both the CloudKit sync scanner and the continuity manifest builder classify
/// through here, so the rules can never diverge between them.
///
/// Design
/// ------
/// - Paths are **relative to iCube's User directory** (the portable `User/`
///   folder), e.g. `"StateSaves/GALE01.s01"`, `"GC/USA/MemoryCardA.raw"`.
/// - This is an **allow-list**: a file syncs only if it positively matches a
///   category below. Anything unrecognised returns `nil`. Never invert this
///   into a blocklist — a blocklist fails open, and failing open here means
///   uploading somebody's ROM library.
/// - Pure and synchronous: no filesystem, no network, no I/O. That is what
///   makes the "no ROM ever leaves the device" guarantee testable.
///
/// Decisions recorded here rather than rediscovered
/// ------------------------------------------------
/// - **Artwork is not synced.** `Cache/GameCovers/` is a cache, re-derivable
///   from the remote art sources the app already queries. Matches iFly, which
///   has no case for it at all.
/// - **Wii NAND saves are synced, capped.** They are irreplaceable game
///   progress. Only the save subtree is allowed, not the whole NAND — system
///   titles and IOS are neither ours to copy nor useful on another device.
/// - **BIOS/IPL is never synced.** A GameCube IPL dump is copyrighted console
///   firmware; it is excluded explicitly rather than by omission.
public enum SyncClassifier {

    /// Largest file that may ever be uploaded or offered to a peer. Every
    /// legitimate category here is far smaller; this is the guard that catches
    /// anything that slipped past the path rules.
    public static let maxFileSizeBytes: Int64 = 64 * 1024 * 1024 // 64 MB

    // MARK: - Hard exclusions, applied before the allow-list

    /// Top-level directories under `User/` that never sync: caches and derived
    /// data (rebuildable), dumps and logs (device-local and huge), installed
    /// texture packs (`Load/`, gigabytes and not user-created).
    private static let excludedTopLevelDirectories: Set<String> = [
        "cache", "dump", "logs", "load", "shaders", "maps",
        "backup", "resourcepacks", "screenshots", "tmp"
    ]

    /// Disc images and executables. Present as belt-and-braces: ROMs live
    /// outside the User directory entirely, so this only matters if a user
    /// dropped one in. `.bin` is deliberately NOT here — Wii NAND save data
    /// uses `.bin`, and is matched by path before extension rules apply.
    private static let romExtensions: Set<String> = [
        "iso", "gcm", "gcz", "wbfs", "rvz", "ciso", "wia", "wad",
        "dol", "elf", "nkit", "m3u", "img", "dff", "zip", "7z", "rar"
    ]

    /// Names that never sync regardless of location.
    private static let excludedNames: Set<String> = [
        ".ds_store", "dolphin.log", "ipl.bin"
    ]

    // MARK: - Classification

    /// Classify a User-directory-relative path, or return `nil` if it must not
    /// leave the device.
    ///
    /// - Parameter relativePath: path relative to the `User/` directory, using
    ///   `/` separators and no leading slash.
    public static func classify(relativePath: String) -> SyncableFileType? {
        let normalized = relativePath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        let components = normalized.split(separator: "/").map(String.init)
        guard let top = components.first else { return nil }
        let name = components[components.count - 1]
        let ext = (name as NSString).pathExtension

        // --- Hard excludes, first and unconditionally ---
        if excludedNames.contains(name) { return nil }
        if excludedTopLevelDirectories.contains(top) { return nil }
        // A GameCube IPL dump is copyrighted firmware wherever it sits.
        if name.hasSuffix("ipl.bin") { return nil }

        // --- Allow-list, most specific first ---

        // Save states and their siblings. Slots are `{GameID}.s{NN}`; the
        // resume state is `{GameID}.auto`. Both carry optional `.json` and
        // `.png` siblings.
        if top == "statesaves", components.count >= 2 {
            if ext == "auto" { return .resumeState }
            if ext == "json" { return .saveStateMetadata }
            if ext == "png" { return .saveStateThumbnail }
            if isNumberedStateSlot(ext) { return .saveState }
            return nil
        }

        // GameCube memory cards: `.raw` images and individual `.gci` saves.
        // Anything else under GC/ (notably an IPL dump) is rejected.
        if top == "gc" {
            if ext == "raw" || ext == "gci" { return .gameCubeMemoryCard }
            return nil
        }

        // Wii NAND. Only the save subtree and the system config, never the
        // whole NAND — system titles and IOS are not ours to copy.
        if top == "wii" {
            if components.contains("data") { return .wiiSave }
            if name == "sysconf" { return .wiiSave }
            return nil
        }

        // Global configuration.
        if top == "config", ext == "ini" { return .config }

        // Per-game settings. NOTE: this file also contains cheats in iCube.
        if top == "gamesettings", ext == "ini" { return .gameSettings }

        // --- Everything else ---
        if romExtensions.contains(ext) { return nil }

        // Default deny. Missing a new save type is a one-line fix; uploading a
        // ROM is not.
        return nil
    }

    /// Whether a directory is worth walking into at all.
    ///
    /// Purely an optimisation: every file under a directory this rejects would
    /// also be rejected by `classify`, so skipping the subtree can never change
    /// what syncs — it only avoids enumerating (and, for the scanner, hashing)
    /// tens of thousands of files under `Cache/`, `Dump/` and `Load/`. A texture
    /// pack alone can be gigabytes.
    ///
    /// - Parameter relativePath: directory path relative to `User/`, same form
    ///   as `classify(relativePath:)` takes.
    /// - Returns: `false` only when nothing under the directory could ever sync.
    ///
    /// - Note: added for WS-5's scanner. Deliberately conservative — it consults
    ///   the same `excludedTopLevelDirectories` set `classify` does, so the two
    ///   cannot disagree.
    public static func shouldDescend(intoDirectoryRelativePath relativePath: String) -> Bool {
        let normalized = relativePath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        // The root itself is always walked.
        guard !normalized.isEmpty else { return true }
        guard let top = normalized.split(separator: "/").first.map(String.init) else { return true }
        return !excludedTopLevelDirectories.contains(top)
    }

    /// Whether a file of this size may leave the device. Applied in addition to
    /// `classify`, never instead of it.
    public static func isWithinSizeLimit(_ sizeBytes: Int64) -> Bool {
        sizeBytes >= 0 && sizeBytes <= maxFileSizeBytes
    }

    /// Both rules together: the question every caller actually wants answered.
    public static func syncableType(relativePath: String, sizeBytes: Int64) -> SyncableFileType? {
        guard isWithinSizeLimit(sizeBytes) else { return nil }
        return classify(relativePath: relativePath)
    }

    /// `s00`...`s99` — a numbered save-state slot extension.
    private static func isNumberedStateSlot(_ ext: String) -> Bool {
        guard ext.count == 3, ext.hasPrefix("s") else { return false }
        return ext.dropFirst().allSatisfy(\.isNumber)
    }
}
