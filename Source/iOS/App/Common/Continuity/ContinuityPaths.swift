// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVContinuity
import PVSyncRules

/// Translation between iCube's on-disk layout and the User-directory-relative
/// paths continuity manifests speak.
///
/// There is exactly one root, `UserFolderUtil.getUserFolder()`, and it is NOT
/// the documents directory: on tvOS it is Caches, and on a jailbroken build it
/// is `/private/var/mobile/Documents/iCube`. Anchoring anything here on
/// `.documentDirectory` would compile everywhere and silently resolve to the
/// wrong place on the platform where this feature has no alternative discovery
/// path at all.
enum ContinuityPaths {

    /// Absolute URL of the User directory — the root every `relativePath` in a
    /// manifest is measured from.
    static var userRoot: URL {
        URL(fileURLWithPath: UserFolderUtil.getUserFolder(), isDirectory: true)
    }

    /// Absolute URL for a User-directory-relative path.
    static func absoluteURL(forRelativePath relativePath: String) -> URL {
        userRoot.appendingPathComponent(relativePath)
    }

    /// User-directory-relative path for an absolute one, or nil when the file
    /// lies outside the User directory entirely.
    ///
    /// Both sides are standardised first, so a path that reaches the root via
    /// `..` or a `/private` vs `/var` symlink difference still resolves. A file
    /// outside the root returns nil rather than a `../`-prefixed path — such a
    /// path could never be recreated safely on the receiving device.
    static func relativePath(forAbsolutePath absolutePath: String) -> String? {
        let root = userRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let file = URL(fileURLWithPath: absolutePath)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard file.hasPrefix(prefix) else { return nil }
        return String(file.dropFirst(prefix.count))
    }

    /// Size and SHA-256 of a file, or nil when it cannot be read.
    ///
    /// Hashing is streamed (see `ContinuityHash`), so calling this on a
    /// multi-gigabyte disc image is slow but not fatal. Callers on the serving
    /// side should not do it on the main thread.
    static func describe(
        relativePath: String,
        kind: ContinuityFileKind,
        required: Bool = true
    ) -> FileDescriptor? {
        let url = absoluteURL(forRelativePath: relativePath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64,
              let hash = try? ContinuityHash.sha256Hex(ofFileAt: url) else { return nil }
        return FileDescriptor(
            kind: kind,
            relativePath: relativePath,
            sha256: hash,
            size: size,
            modifiedAt: attributes[.modificationDate] as? Date,
            required: required
        )
    }
}

// MARK: - Library bridging

extension GameIdentity {
    /// Builds an identity from a library entry.
    ///
    /// `gameID`, `discNumber` and `revision` all come from the disc header via
    /// `TVGameItem`, which is what makes an `.exactGameID` match meaningful:
    /// without the disc and revision, two discs of the same title and two
    /// revisions of the same game would claim to be identical.
    ///
    /// No MD5 is computed here. Hashing a disc image costs minutes, and the
    /// ID/disc/revision triple already answers the question for every title
    /// Dolphin can read a header from. `md5` stays nil and the ladder simply
    /// never reaches its content-hash rung — which is a weaker match, not a
    /// wrong one.
    init(gameItem: TVGameItem) {
        self.init(
            gameID: gameItem.gameID,
            displayName: gameItem.title,
            platform: GameIdentity.platformSlug(forDiscIOPlatform: gameItem.platform),
            discNumber: gameItem.discNumber,
            revision: gameItem.revision
        )
    }

    /// `DiscIO::Platform` raw values, per `TVGameItem`'s own documentation:
    /// 0 = GameCube disc, 1 = Wii disc, 2 = Wii WAD, 3 = ELF/DOL.
    ///
    /// Only the GameCube/Wii split matters to a peer (it decides which save
    /// layout the payload uses), so anything that is not a GameCube disc is
    /// reported as Wii rather than inventing slugs a receiver would ignore.
    static func platformSlug(forDiscIOPlatform platform: Int) -> String {
        platform == 0 ? "gc" : "wii"
    }
}
