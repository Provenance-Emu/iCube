// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVContinuity

/// Resolves a remote game identity against iCube's local library.
///
/// Matching is delegated entirely to `GameIdentity.match(against:)` so the
/// ladder lives in one place. This type's only job is to walk the library and
/// keep the strongest match, plus answer "does this title already have a save
/// state here?" — the fact the fallback ladder's `bootWithLatestLocalState`
/// rung turns on.
struct ICubeLibraryQuery: LibraryQuerying {

    func resolveLocalGame(_ identity: GameIdentity) async -> LocalGameMatch? {
        let items = await MainActor.run { TVLibraryBridge.currentGames() }

        var best: LocalGameMatch?
        var bestIsModded = false
        for item in items {
            // A screenshot-mode placeholder has no backing GameFile and must
            // never be offered as a boot target.
            guard !item.isDemoItem else { continue }
            guard let strength = identity.match(against: GameIdentity(gameItem: item)) else { continue }

            // The library's own absolute path, passed through untouched. A game
            // imported in place from Files lives outside the User directory and
            // has no relative form; it is still perfectly bootable.
            let candidate = LocalGameMatch(
                strength: strength,
                gameAbsolutePath: item.filePath,
                hasLocalSaveState: Self.hasSaveState(gameID: item.gameID)
            )
            let isModded = ModdedBoot.isModdedPath(item.filePath)
            if let current = best, !Self.prefers(strength: strength, isModded: isModded, over: (current.strength, bestIsModded)) {
                continue
            }
            best = candidate
            bestIsModded = isModded
        }
        return best
    }

    /// `IdentityMatchStrength` is Comparable with the strongest case lowest, so a smaller raw value wins. A patched
    /// copy keeps its base game's ID and so ties with it; the pristine game is the safer thing to hand to a
    /// continuity handoff, because the handoff's save state belongs to the base game.
    static func prefers(strength: IdentityMatchStrength, isModded: Bool, over best: (strength: IdentityMatchStrength, isModded: Bool)) -> Bool {
        strength < best.strength || (strength == best.strength && best.isModded && !isModded)
    }

    /// True when any `{GameID}.s{NN}` or `{GameID}.auto` exists locally.
    private static func hasSaveState(gameID: String) -> Bool {
        guard !gameID.isEmpty else { return false }
        let directory = ContinuityPaths.absoluteURL(
            forRelativePath: SaveStateDescriptor.stateSavesDirectory
        )
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        return names.contains { name in
            guard name.hasPrefix("\(gameID).") else { return false }
            let ext = (name as NSString).pathExtension
            if ext == "auto" { return true }
            return ext.count == 3 && ext.hasPrefix("s") && ext.dropFirst().allSatisfy(\.isNumber)
        }
    }
}
