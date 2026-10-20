// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVContinuity

/// Mints the save state a handoff resumes from.
///
/// Minting is lazy — it happens when the receiving device asks, so the state is
/// seconds old rather than whatever the last autosave managed.
///
/// ## The stem
///
/// The state is written through `TVEmulationBridge.saveStateToPath:`, using the
/// path `TVEmulationBridge.stateFilePathForSlot:` produced — i.e. the core's own
/// `{GameID}.s{NN}`. The stem reported in the descriptor is read back out of
/// that path, never composed from the ROM basename or the display title. See
/// the stem rule on `SaveStateDescriptor`.
///
/// ## The slot
///
/// A dedicated high slot, so handing a game off never overwrites a slot the
/// user was keeping. Dolphin's own slot UI runs 1–10; 99 is outside it and
/// still matches the `s{NN}` two-digit filename shape the classifier accepts.
struct ICubeSaveStateMinter: SaveStateMinting {

    /// The slot handoff states are written to. Deliberately outside the 1–10
    /// range the save UI offers.
    static let handoffSlot = 99

    var saveSnapshot: @Sendable (Int, String?, UInt64) async -> SaveStateCompletedSnapshot? = { slot, gameID, session in
        await SaveStateService.saveSlotSnapshotAsync(slot, expectedGameID: gameID, expectedSessionIdentifier: session)
    }

    func mintHandoffState(identity: GameIdentity) async throws -> SaveStateDescriptor {
        let session = await MainActor.run { TVEmulationBridge.currentSessionIdentifier() }
        guard let snapshot = await saveSnapshot(Self.handoffSlot, identity.gameID, session) else {
            throw ContinuityError.noActiveSession
        }
        let absolutePath = snapshot.filePath

        let url = URL(fileURLWithPath: absolutePath)
        guard let relativePath = ContinuityPaths.relativePath(forAbsolutePath: absolutePath) else {
            throw ContinuityError.noActiveSession
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64, size > 0 else {
            // The file never appeared: report it rather than describing a state
            // that is not there, which the receiver would fail to verify after
            // transferring nothing.
            throw ContinuityError.noActiveSession
        }
        let hash = try ContinuityHash.sha256Hex(ofFileAt: url)

        // The stem comes back OUT of the core-produced filename. `GALE01.s99`
        // → `GALE01`; deleting one path extension is exactly right for the
        // `{stem}.s{NN}` shape and does not touch the stem itself.
        let stem = url.deletingPathExtension().lastPathComponent

        return SaveStateDescriptor(
            slot: Self.handoffSlot,
            stem: stem,
            relativePath: relativePath,
            sha256: hash,
            size: size,
            thumbnailRelativePath: siblingIfPresent(relativePath, extension: "png"),
            metadataRelativePath: siblingIfPresent(relativePath, extension: "json")
        )
    }

    private func siblingIfPresent(_ relativePath: String, extension ext: String) -> String? {
        let candidate = "\(relativePath).\(ext)"
        let url = ContinuityPaths.absoluteURL(forRelativePath: candidate)
        return FileManager.default.fileExists(atPath: url.path) ? candidate : nil
    }
}
