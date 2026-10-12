// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The single source of truth for which files may leave the device.
///
/// Both the sync scanner and the continuity manifest builder classify through
/// here, so the rules can never diverge between them.
///
/// Design
/// ------
/// - Paths are **relative to iCube's User directory** (Dolphin's portable
///   `User/` folder, which on iOS is the app's Documents folder), e.g.
///   `"StateSaves/GALE01.s01"`, `"GC/USA/MemoryCardA.raw"`.
/// - This is an **allow-list**: a file syncs only if it positively matches a
///   category below. Anything unrecognised returns `nil`. Never invert this
///   into a blocklist — a blocklist fails open, and failing open here means
///   uploading somebody's ROM library.
/// - Pure and synchronous: no filesystem, no network, no I/O, and **no
///   policy**. Whether an opt-in category is currently switched on is
///   `SyncPolicy`'s question. The classifier answers only "what is this file",
///   so a record written by a device with different switches still lands in
///   the right category here.
///
/// Decisions recorded here rather than rediscovered
/// ------------------------------------------------
/// - **Artwork is not synced.** `Cache/GameCovers/` is a cache, re-derivable
///   from the remote art sources the app already queries.
/// - **Disc images never classify**, by extension and by directory
///   (`Software/`). The content server and the planned shared iCloud Drive
///   folder are the places for games; this engine is for the user's own data.
/// - **Firmware, Wii channels and the rest of the NAND classify, but opt-in.**
///   They used to be hard exclusions. They are the user's own dumps going to
///   the user's own private database, so the user gets the switch; the default
///   is off, and `SyncPolicy` keeps them off until it is flipped.
public enum SyncClassifier {

    /// Default per-file cap. Categories with a larger legitimate payload
    /// override it through `SyncableFileType.maxFileSizeBytes`.
    public static let maxFileSizeBytes: Int64 = 64 * 1024 * 1024 // 64 MB

    // MARK: - Hard exclusions, applied before the allow-list

    /// Top-level directories under `User/` that never sync: caches and derived
    /// data (rebuildable), dumps and logs (device-local and huge), installed
    /// texture packs (`Load/`, gigabytes and not user-created), and the game
    /// library itself.
    private static let excludedTopLevelDirectories: Set<String> = [
        "cache", "dump", "logs", "load", "shaders", "maps",
        "backup", "resourcepacks", "screenshots", "tmp", "software"
    ]

    /// Disc images, installers and archives. Belt and braces: ROMs live under
    /// `Software/`, which is excluded wholesale, so this only matters if a user
    /// dropped one somewhere else. `.bin` is deliberately NOT here — Wii NAND
    /// data uses `.bin`, and is matched by path before extension rules apply.
    private static let romExtensions: Set<String> = [
        "iso", "gcm", "gcz", "wbfs", "rvz", "ciso", "wia", "wad",
        "dol", "elf", "nkit", "m3u", "img", "dff", "zip", "7z", "rar"
    ]

    /// Names that never sync regardless of location.
    private static let excludedNames: Set<String> = [
        ".ds_store", "dolphin.log"
    ]

    /// Wii NAND subtrees that are transient scratch space.
    private static let excludedWiiDirectories: Set<String> = ["tmp", "import"]

    /// Title-type high words that are user-installed content: channels and
    /// WiiWare (`00010001`), disc-installed channels (`00010004`), DLC
    /// (`00010005`) and hidden channels (`00010008`). Everything else under
    /// `title/` and `ticket/` is system software.
    private static let channelTitleTypes: Set<String> = [
        "00010001", "00010004", "00010005", "00010008"
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
        if romExtensions.contains(ext) { return nil }

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

        // GameCube: memory cards always; the IPL dump as opt-in firmware.
        if top == "gc" {
            if ext == "raw" || ext == "gci" { return .gameCubeMemoryCard }
            if name == "ipl.bin", components.count <= 3 { return .firmware }
            return nil
        }

        // Integrated GBA saves.
        if top == "gba", components.count >= 3, components[1] == "saves" {
            return .gbaSave
        }

        if top == "wii" { return classifyWii(components: components, name: name) }

        // Global configuration (controller INIs included).
        if top == "config", ext == "ini", components.count == 2 { return .config }

        // Per-game settings. NOTE: this file also contains cheats in iCube.
        if top == "gamesettings", ext == "ini", components.count == 2 { return .gameSettings }

        // iCube's own JSON stores next to Dolphin's tree.
        if top == "profiles", components.count == 2, ext == "json" {
            if name == "game_profiles.json" { return .gameProfile }
            if name == "library_state.json" { return .libraryState }
            if name.hasPrefix("touch_overlay_layout") { return .touchOverlayLayout }
            return nil
        }

        // Controller skins: the pick file and every file inside an installed
        // skin folder. Archives were rejected above, so a skin that is still a
        // `.zip` or `.deltaskin` in flight never syncs.
        if top == "skins", components.count >= 2 {
            if components.count == 2 {
                return name == "selection.json" ? .skin : nil
            }
            return .skin
        }

        // Default deny. Missing a new save type is a one-line fix; uploading a
        // ROM is not.
        return nil
    }

    /// The Wii NAND. `components` starts with `"wii"`.
    private static func classifyWii(components: [String], name: String) -> SyncableFileType? {
        guard components.count >= 2 else { return nil }
        let second = components[1]
        if excludedWiiDirectories.contains(second) { return nil }

        // The system configuration rides with saves wherever it sits.
        if name == "sysconf" { return .wiiSave }

        switch second {
        case "title":
            // wii/title/<type>/<id>/...
            guard components.count >= 4 else { return nil }
            // Save data for any title, disc games included.
            if components.dropFirst(4).contains("data") { return .wiiSave }
            return channelTitleTypes.contains(components[2]) ? .wiiChannel : .wiiSystem

        case "ticket":
            // wii/ticket/<type>/<id>.tik
            guard components.count >= 4 else { return nil }
            return channelTitleTypes.contains(components[2]) ? .wiiChannel : .wiiSystem

        case "shared1":
            // Shared contents that installed channels reference.
            return components.count >= 3 ? .wiiChannel : nil

        default:
            // shared2 (minus SYSCONF), sys, meta, and anything Dolphin adds.
            return components.count >= 3 ? .wiiSystem : nil
        }
    }

    /// Whether a directory is worth walking into at all.
    ///
    /// Purely an optimisation: every file under a directory this rejects would
    /// also be rejected by `classify`, so skipping the subtree can never change
    /// what syncs — it only avoids enumerating (and, for the scanner, hashing)
    /// tens of thousands of files under `Cache/`, `Dump/`, `Load/` and the game
    /// library.
    ///
    /// - Parameter relativePath: directory path relative to `User/`, same form
    ///   as `classify(relativePath:)` takes.
    /// - Returns: `false` only when nothing under the directory could ever sync.
    public static func shouldDescend(intoDirectoryRelativePath relativePath: String) -> Bool {
        let normalized = relativePath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        // The root itself is always walked.
        guard !normalized.isEmpty else { return true }
        let components = normalized.split(separator: "/").map(String.init)
        guard let top = components.first else { return true }
        if excludedTopLevelDirectories.contains(top) { return false }
        if top == "wii", components.count >= 2, excludedWiiDirectories.contains(components[1]) {
            return false
        }
        return true
    }

    /// Whether a directory can be skipped under the given policy. Unlike
    /// `shouldDescend`, this one *is* a policy question: with the NAND switches
    /// off, walking `Wii/title/00000001/` only to reject every file is wasted
    /// hashing. Save data lives under the same `title/` tree, so only the
    /// subtrees that can contain nothing allowed are pruned.
    public static func shouldDescend(
        intoDirectoryRelativePath relativePath: String,
        policy: SyncPolicy
    ) -> Bool {
        guard shouldDescend(intoDirectoryRelativePath: relativePath) else { return false }
        let components = relativePath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
            .split(separator: "/").map(String.init)
        guard components.count >= 2, components[0] == "wii" else { return true }
        switch components[1] {
        case "shared1":
            return policy.allows(.wiiChannel)
        case "ticket":
            // Tickets never hold save data; prune by title type when known.
            if components.count >= 3 {
                let type = channelTitleTypes.contains(components[2]) ? SyncableFileType.wiiChannel : .wiiSystem
                return policy.allows(type)
            }
            return policy.allows(.wiiChannel) || policy.allows(.wiiSystem)
        default:
            return true
        }
    }

    /// Whether a file of this size may leave the device, under the default cap.
    public static func isWithinSizeLimit(_ sizeBytes: Int64) -> Bool {
        sizeBytes >= 0 && sizeBytes <= maxFileSizeBytes
    }

    /// Whether a file of this size and category may leave the device.
    public static func isWithinSizeLimit(_ sizeBytes: Int64, for type: SyncableFileType) -> Bool {
        sizeBytes >= 0 && sizeBytes <= type.maxFileSizeBytes
    }

    /// Both rules together: the question every caller actually wants answered.
    /// The cap is the category's own, so a 200 MB channel is allowed while a
    /// 200 MB file pretending to be a save state is not.
    public static func syncableType(relativePath: String, sizeBytes: Int64) -> SyncableFileType? {
        guard let type = classify(relativePath: relativePath) else { return nil }
        guard isWithinSizeLimit(sizeBytes, for: type) else { return nil }
        return type
    }

    /// Classification plus policy: the category if the file may sync *right
    /// now*, under this user's switches.
    public static func syncableType(
        relativePath: String,
        sizeBytes: Int64,
        policy: SyncPolicy
    ) -> SyncableFileType? {
        guard let type = syncableType(relativePath: relativePath, sizeBytes: sizeBytes) else { return nil }
        return policy.allows(type) ? type : nil
    }

    /// `s00`...`s99` — a numbered save-state slot extension.
    private static func isNumberedStateSlot(_ ext: String) -> Bool {
        guard ext.count == 3, ext.hasPrefix("s") else { return false }
        return ext.dropFirst().allSatisfy(\.isNumber)
    }
}
