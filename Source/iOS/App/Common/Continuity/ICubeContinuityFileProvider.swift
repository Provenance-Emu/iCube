// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVContinuity
import PVSyncRules

/// Maps continuity's abstract file kinds onto iCube's on-disk layout.
///
/// ## Scope of a handoff payload, and what that implies
///
/// GameCube saves live in region-wide memory-card images (`GC/USA/MemoryCardA.raw`)
/// and Wii saves live in a shared NAND tree — neither is per-game. So a handoff
/// that carries "this game's saves" unavoidably carries **every game's saves for
/// that region / on that NAND**. That is correct for the case this feature was
/// built for (continuing your own game on your own second device) and is the same
/// shape iFly ships for VMU cards.
///
/// It is worth being explicit that it is also true when the peer is somebody
/// else's paired device. A user handing a game to a friend hands over their
/// memory card. If nearby *library* sharing (WS-4 task 8) is built on top of
/// this provider, it must not reuse `handoffUserDataKinds` unchanged — a
/// browsing stranger pulling a game should get the game, not the owner's saves.
struct ICubeContinuityFileProvider: ContinuityFileProviding {

    /// Absolute path of the disc image currently being served.
    ///
    /// A closure rather than a stored path: the provider is constructed once at
    /// launch when the routes are registered, long before any game is booted,
    /// so a captured value would be permanently nil. The core does not expose
    /// the booted path in a form that can be read back reliably, so the manager
    /// supplies it from the library entry the user actually launched.
    let currentGameFilePath: @Sendable () -> String?

    /// Enumerating the Wii NAND walks a tree that can hold hundreds of titles.
    /// Cap the walk so a pathological NAND cannot stall a manifest build; the
    /// cap is far above any plausible single-user save set.
    private static let maxEnumeratedFiles = 512

    // MARK: - Serving

    func enumerate(kind: ContinuityFileKind, identity: GameIdentity) async throws -> [FileDescriptor] {
        switch kind {
        case .gameFile:
            return gameFileDescriptors()
        case .gameSettings:
            return gameSettingsDescriptors(identity: identity)
        case .saveStateMetadata, .saveStateThumbnail:
            return saveStateSidecarDescriptors(kind: kind, identity: identity)
        case .gameCubeMemoryCard:
            return walk(directory: "GC", expecting: .gameCubeMemoryCard)
        case .wiiSave:
            return walk(directory: "Wii", expecting: .wiiSave)
        case .saveState, .resumeState:
            // States travel as the manifest's `saveState`, minted on demand.
            // Enumerating every slot would multiply the payload by ten for no
            // benefit — the receiving device resumes from one point.
            return []
        case .config:
            // Deliberately never offered; see ContinuityManifestBuilder.
            return []
        }
    }

    func fileURL(for descriptor: FileDescriptor) async throws -> URL {
        ContinuityPaths.absoluteURL(forRelativePath: descriptor.relativePath)
    }

    // MARK: - Receiving

    func localStatus(of descriptor: FileDescriptor) async -> LocalFileStatus {
        let url = ContinuityPaths.absoluteURL(forRelativePath: descriptor.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }

        // Size first: it is O(1) and rules out most mismatches without hashing
        // a multi-gigabyte disc image.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? Int64, size == descriptor.size else {
            return .presentDiffering
        }

        guard let hash = try? ContinuityHash.sha256Hex(ofFileAt: url) else { return .presentDiffering }
        return hash == descriptor.sha256 ? .presentMatching : .presentDiffering
    }

    func destinationURL(for descriptor: FileDescriptor) async throws -> URL {
        // The same relative path as on the source device, under THIS device's
        // User directory. Save states bind to games by filename stem and memory
        // cards bind by directory, so the layout has to survive the trip.
        ContinuityPaths.absoluteURL(forRelativePath: descriptor.relativePath)
    }

    // MARK: - Enumeration helpers

    private func gameFileDescriptors() -> [FileDescriptor] {
        guard let gameFilePath = currentGameFilePath(),
              let relative = ContinuityPaths.relativePath(forAbsolutePath: gameFilePath) else {
            // The disc image lives outside the User directory (imported in
            // place from Files, say). It cannot be offered, because the
            // receiving device has nowhere to reproduce the path. The receiver
            // then needs the game locally, and the fallback ladder says so
            // clearly rather than handing over a file that lands nowhere.
            return []
        }
        return ContinuityPaths.describe(relativePath: relative, kind: .gameFile).map { [$0] } ?? []
    }

    private func gameSettingsDescriptors(identity: GameIdentity) -> [FileDescriptor] {
        guard let gameID = identity.gameID, !gameID.isEmpty else { return [] }
        // NOTE: in iCube this one file also carries cheats — see the comment on
        // SyncableFileType.gameSettings. Transferring it transfers both.
        let relative = "GameSettings/\(gameID).ini"
        return ContinuityPaths.describe(relativePath: relative, kind: .gameSettings, required: false)
            .map { [$0] } ?? []
    }

    /// The `.json` / `.png` siblings of the game's save-state slots.
    ///
    /// Marked non-required: a missing thumbnail costs a placeholder in the save
    /// browser, which must never be the reason a handoff reports failure.
    private func saveStateSidecarDescriptors(
        kind: ContinuityFileKind, identity: GameIdentity
    ) -> [FileDescriptor] {
        guard let gameID = identity.gameID, !gameID.isEmpty else { return [] }
        let directory = ContinuityPaths.absoluteURL(
            forRelativePath: SaveStateDescriptor.stateSavesDirectory
        )
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        let wantedExtension = (kind == .saveStateMetadata) ? "json" : "png"
        return names
            .filter { $0.hasPrefix("\(gameID).") && ($0 as NSString).pathExtension == wantedExtension }
            .sorted()
            .compactMap {
                ContinuityPaths.describe(
                    relativePath: "\(SaveStateDescriptor.stateSavesDirectory)/\($0)",
                    kind: kind,
                    required: false
                )
            }
    }

    /// Walks a User-directory subtree and keeps only files `SyncClassifier`
    /// classifies as `expecting`.
    ///
    /// Classification, not extension matching, is what decides: that way this
    /// walk inherits every exclusion the shared table already encodes (IPL
    /// dumps, cache directories, oversized files) instead of restating them —
    /// and restating them is how the two would drift apart.
    private func walk(directory: String, expecting: SyncableFileType) -> [FileDescriptor] {
        let root = ContinuityPaths.absoluteURL(forRelativePath: directory)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var descriptors: [FileDescriptor] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > Self.maxEnumeratedFiles { break }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let relative = ContinuityPaths.relativePath(forAbsolutePath: url.path),
                  let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64,
                  SyncClassifier.syncableType(relativePath: relative, sizeBytes: size) == expecting,
                  let descriptor = ContinuityPaths.describe(
                    relativePath: relative, kind: ContinuityFileKind(expecting), required: false
                  )
            else { continue }
            descriptors.append(descriptor)
        }
        return descriptors
    }
}
