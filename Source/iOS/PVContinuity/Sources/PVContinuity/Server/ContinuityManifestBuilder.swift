// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVSyncRules

/// Assembles a `ContinuityManifest` from a file provider.
///
/// ## The allow-list is applied here, once
///
/// Every **user-data** descriptor the provider hands back is re-checked through
/// `SyncClassifier` before it reaches a manifest: the classifier must agree
/// that the path is syncable, that the size is within the cap, and that the
/// category it derives from the path is the one the provider claimed. A
/// provider bug — an over-broad directory enumeration, a symlink followed into
/// the ROM folder — therefore cannot put a file on the wire.
///
/// The **game file** is the single exception, and it is added explicitly by
/// this type rather than by anything the classifier returns, because a disc
/// image is by design something `SyncClassifier` always rejects. See the type
/// doc on `ContinuityFileKind` for why that asymmetry is correct rather than a
/// gap.
public struct ContinuityManifestBuilder: Sendable {
    private let fileProvider: any ContinuityFileProviding
    private let sourceDevice: SourceDevice

    public init(fileProvider: any ContinuityFileProviding, sourceDevice: SourceDevice) {
        self.fileProvider = fileProvider
        self.sourceDevice = sourceDevice
    }

    /// User-data categories a handoff carries. Config is deliberately absent:
    /// a global `Dolphin.ini` is device-specific (backend, resolution, control
    /// layout) and pushing the sender's onto the receiver would be a hostile
    /// surprise. Per-game settings DO travel, because they are the ones that
    /// change how the game itself runs.
    public static let handoffUserDataKinds: [ContinuityFileKind] = [
        .gameSettings,
        .gameCubeMemoryCard,
        .wiiSave,
        .saveStateMetadata,
        .saveStateThumbnail
    ]

    /// Builds the manifest for one game.
    ///
    /// - Parameters:
    ///   - includeGameFile: whether to offer the disc image. False when the
    ///     receiving device already resolved the game locally — there is no
    ///     point offering gigabytes it will skip, and not offering it keeps the
    ///     file route's allow-list correspondingly narrow.
    public func build(
        game: GameIdentity,
        sessionId: String,
        saveState: SaveStateDescriptor? = nil,
        includeGameFile: Bool = true
    ) async throws -> ContinuityManifest {
        var files: [FileDescriptor] = []

        if includeGameFile {
            files += try await fileProvider.enumerate(kind: .gameFile, identity: game)
        }
        for kind in Self.handoffUserDataKinds {
            let enumerated = try await fileProvider.enumerate(kind: kind, identity: game)
            files += enumerated.filter { Self.isPermitted($0) }
        }

        // Dedupe: the save state travels as `saveState`, and a provider that
        // also lists it under metadata/thumbnail enumeration would otherwise
        // produce two descriptors for one path.
        var seen = Set<String>()
        if let saveState { seen.insert(saveState.relativePath) }
        files = files.filter { seen.insert($0.relativePath).inserted }

        return ContinuityManifest(
            sessionId: sessionId,
            mintedAt: Date(),
            sourceDevice: sourceDevice,
            game: game,
            saveState: saveState,
            files: files
        )
    }

    /// The allow-list check. A descriptor passes only if `SyncClassifier` both
    /// permits its path and derives the same category the provider claimed.
    ///
    /// The category cross-check is the part that matters: without it, a
    /// provider could label a disc image `.gameSettings` and slip it past a
    /// path check that only asked "is this syncable at all?".
    static func isPermitted(_ descriptor: FileDescriptor) -> Bool {
        guard descriptor.kind != .gameFile else { return false }
        guard let classified = SyncClassifier.syncableType(
            relativePath: descriptor.relativePath,
            sizeBytes: descriptor.size
        ) else { return false }
        return ContinuityFileKind(classified) == descriptor.kind
    }
}
