// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVContinuity
import UIKit

/// Serves iCube's library to devices browsing it over Nearby Sharing.
///
/// ## Why this is not `ICubeContinuityFileProvider`
///
/// That type exists to describe a **handoff** payload: the user's own save data
/// following them to their own second device. Its `enumerate(kind:identity:)`
/// hands back region-wide GameCube memory cards and slices of the Wii NAND,
/// because for that use that is correct — and its own type doc warns, in as
/// many words, that nearby library sharing must not reuse
/// `handoffUserDataKinds`.
///
/// This type is that warning honoured. It has no `kind:` parameter at all:
/// there is no argument you can pass it that returns a memory card, a save
/// state, or a per-game INI. The only bytes it can produce are a disc image and
/// a cover PNG.
struct ICubeLibraryProvider: ContinuityLibraryProviding {

    /// Cover art is re-encoded to PNG on demand, which is not free. Keep it
    /// modest: a browsing peer asks for one cover per visible row, and a
    /// gigantic source image would be resized by the peer anyway.
    private static let artworkMaxDimension: CGFloat = 512

    func allEntries() async -> [ContinuityLibraryEntry] {
        let items = await MainActor.run { TVLibraryBridge.currentGames() }
        var entries: [ContinuityLibraryEntry] = []
        var seen = Set<String>()
        for item in items {
            // A screenshot-mode placeholder has no backing GameFile. Offering
            // one would advertise a title this device cannot actually send.
            guard !item.isDemoItem else { continue }
            let identity = GameIdentity(gameItem: item)
            guard identity.hasAnyIdentifier else { continue }
            // Two discs of the same title share a GameID but differ by
            // `discNumber`, which `stableKey` includes — so a collision here
            // means a genuinely duplicated library entry, and offering it twice
            // would just make the browser show it twice.
            guard seen.insert(identity.stableKey).inserted else { continue }
            entries.append(ContinuityLibraryEntry(
                game: identity,
                sizeBytes: Int64(item.fileSize),
                hasArtwork: true
            ))
        }
        return entries.sorted { $0.game.displayName.localizedCaseInsensitiveCompare($1.game.displayName) == .orderedAscending }
    }

    /// Consulted live on every request, so flipping the switch in the library's
    /// context menu takes effect on a peer's very next request.
    func isExcludedFromSharing(key: String) async -> Bool {
        guard let gameID = Self.gameID(forKey: key) else {
            // A key with no GameID cannot be matched against the per-game
            // store, and the safe reading of "cannot tell" is "do not share".
            return true
        }
        return await MainActor.run { GameProfiles.shared.isExcludedFromNearbySharing(gameID: gameID) }
    }

    func artworkPNG(forKey key: String) async -> Data? {
        guard let item = await item(forKey: key) else { return nil }
        let image = await MainActor.run { item.coverImage }
        return Self.pngData(for: image)
    }

    func gameFileDescriptor(forKey key: String) async -> FileDescriptor? {
        guard let item = await item(forKey: key) else { return nil }
        let path = await MainActor.run { item.filePath }
        // A game imported in place from Files lives outside the User directory
        // and has no relative form, so it cannot be offered: the receiving
        // device would have nowhere to reproduce the path. Returning nil makes
        // the route 404, which is honest; the alternative is a transfer that
        // lands nowhere.
        guard let relative = ContinuityPaths.relativePath(forAbsolutePath: path) else { return nil }
        return ContinuityPaths.describe(relativePath: relative, kind: .gameFile)
    }

    func fileURL(for descriptor: FileDescriptor) async throws -> URL {
        ContinuityPaths.absoluteURL(forRelativePath: descriptor.relativePath)
    }

    // MARK: - Helpers

    /// The library entry behind a catalog key, or nil.
    ///
    /// Matched on `stableKey` rather than on GameID alone so that two discs of
    /// one title, or two revisions, resolve to the entry that was actually
    /// offered.
    private func item(forKey key: String) async -> TVGameItem? {
        let items = await MainActor.run { TVLibraryBridge.currentGames() }
        for item in items where !item.isDemoItem {
            if GameIdentity(gameItem: item).stableKey == key { return item }
        }
        return nil
    }

    /// Recovers the six-character GameID from a `stableKey`.
    ///
    /// `GameIdentity.stableKey` is `id:<GameID>|d<disc>|r<rev>` whenever a
    /// GameID exists, and iCube always has one for a disc it can read a header
    /// from. Parsed rather than re-derived so the two cannot drift; a key of
    /// any other shape returns nil and is treated as excluded.
    static func gameID(forKey key: String) -> String? {
        guard key.hasPrefix("id:") else { return nil }
        let body = key.dropFirst("id:".count)
        guard let separator = body.firstIndex(of: "|") else { return nil }
        let gameID = String(body[body.startIndex..<separator])
        return gameID.isEmpty ? nil : gameID
    }

    /// PNG bytes for a cover, downscaled when it is larger than needed.
    private static func pngData(for image: UIImage?) -> Data? {
        guard let image, image.size.width > 0, image.size.height > 0 else { return nil }
        let longest = max(image.size.width, image.size.height)
        guard longest > artworkMaxDimension else { return image.pngData() }

        let scale = artworkMaxDimension / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.pngData()
    }
}
