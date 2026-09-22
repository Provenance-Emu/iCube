// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// How a remote identity was matched against a local library entry, strongest
/// first. The ordering of the cases IS the ladder.
public enum IdentityMatchStrength: Int, Sendable, Codable, Comparable {
    /// Same six-character game ID, same disc, same revision. Byte-for-byte the
    /// same release as far as the emulator is concerned — a save state from one
    /// will load on the other.
    case exactGameID = 0
    /// Identical file content. Strongest possible claim, but only available for
    /// entries both devices have actually hashed.
    case contentHash = 1
    /// Same game ID, but a different disc index or revision. The games are
    /// related; **a save state is not guaranteed to load**, so callers must
    /// treat this as "the right game, possibly the wrong build".
    case gameIDFamily = 2

    public static func < (lhs: IdentityMatchStrength, rhs: IdentityMatchStrength) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Identifies a GameCube/Wii title across devices.
///
/// Why the six-character ID leads
/// ------------------------------
/// Dolphin already uses `SConfig::GetGameID()` as the stem of every save-state
/// filename (`Core/State.cpp MakeStateFilename` → `{GameID}.s{NN}`), of the
/// per-game settings INI, and of the GameCube memory-card directory layout. It
/// is the identifier the whole on-disk layout is keyed by, so matching on
/// anything else would mean a receiving device could "find" the game and still
/// put its pulled files somewhere the emulator never looks.
///
/// Why it is not sufficient on its own
/// -----------------------------------
/// Two things share a game ID:
///   * **Multi-disc titles.** Both discs of a two-disc GameCube game carry the
///     same ID; only `discNumber` (the disc header's disc index) separates them.
///   * **Revisions.** A rev 1 and a rev 2 of the same title share the ID, and a
///     save state made against one may not load against the other.
/// So the ID alone is a *family* match. `md5` (whole-file hash, when a device
/// has computed one) is the tie-breaker, and an exact match additionally
/// requires the disc and revision to agree.
///
/// `crc32` is carried because Dolphin's game list computes it far more cheaply
/// than an MD5 for large RVZ/ISO files; it is a corroborating signal, never a
/// match on its own — 32 bits is not enough to assert two multi-gigabyte discs
/// are the same one.
public struct GameIdentity: Codable, Hashable, Sendable {
    /// The six-character Nintendo game ID, e.g. `GALE01`, `RMCE01`. Uppercased
    /// on construction so a peer that reported it differently still matches.
    public var gameID: String?
    /// Lowercase hex MD5 of the disc image, when this device has one.
    public var md5: String?
    /// Lowercase hex CRC32 of the disc image, when this device has one.
    public var crc32: String?
    public var displayName: String
    /// Platform slug: `gc` or `wii`.
    public var platform: String
    /// Disc index from the disc header (0 for single-disc titles).
    public var discNumber: Int?
    /// Revision byte from the disc header.
    public var revision: Int?

    public init(
        gameID: String? = nil,
        md5: String? = nil,
        crc32: String? = nil,
        displayName: String,
        platform: String,
        discNumber: Int? = nil,
        revision: Int? = nil
    ) {
        self.gameID = gameID.map { $0.uppercased() }
        self.md5 = md5.map { $0.lowercased() }
        self.crc32 = crc32.map { $0.lowercased() }
        self.displayName = displayName
        self.platform = platform
        self.discNumber = discNumber
        self.revision = revision
    }

    /// True when at least one identifier is present. An identity without one
    /// cannot be resolved on a remote device and must never be advertised —
    /// the receiver would have no way to tell what it was being offered.
    public var hasAnyIdentifier: Bool {
        gameID?.isEmpty == false || md5?.isEmpty == false || crc32?.isEmpty == false
    }

    /// Matches `self` (the remote identity) against a local one, returning how
    /// strong the match is, or nil for no match.
    ///
    /// The ladder, strongest first:
    ///   1. **Same game ID, same disc, same revision** → `.exactGameID`.
    ///      Checked first because it is the condition under which the receiving
    ///      device's file layout is guaranteed to line up.
    ///   2. **Identical MD5** → `.contentHash`.
    ///   3. **Same game ID, differing disc or revision** → `.gameIDFamily`.
    ///
    /// A missing field on either side never *creates* a match: nil disc and nil
    /// revision on both sides is treated as "both unknown, therefore equal",
    /// but nil on one side and a value on the other is a disagreement and
    /// demotes the result to `.gameIDFamily`. A CRC32 agreement alone is
    /// deliberately not a match.
    public func match(against local: GameIdentity) -> IdentityMatchStrength? {
        if let mine = gameID, let theirs = local.gameID, !mine.isEmpty, mine == theirs {
            let sameDisc = (discNumber ?? 0) == (local.discNumber ?? 0)
            let sameRevision = revision == local.revision
            if sameDisc && sameRevision { return .exactGameID }
            if let mineMD5 = md5, let theirsMD5 = local.md5, !mineMD5.isEmpty, mineMD5 == theirsMD5 {
                return .contentHash
            }
            return .gameIDFamily
        }
        if let mineMD5 = md5, let theirsMD5 = local.md5, !mineMD5.isEmpty, mineMD5 == theirsMD5 {
            return .contentHash
        }
        return nil
    }

    /// A stable string key for this identity, used as the `id` of a nearby
    /// library manifest entry and as a dictionary key.
    ///
    /// Prefers the ID+disc+revision triple because it is available without
    /// hashing a multi-gigabyte file; falls back to the MD5, then to a
    /// name/platform composite so an entry with no identifier at all still gets
    /// a distinct (if unmatchable) key rather than colliding with every other
    /// unidentified entry.
    public var stableKey: String {
        if let gameID, !gameID.isEmpty {
            return "id:\(gameID)|d\(discNumber ?? 0)|r\(revision ?? -1)"
        }
        if let md5, !md5.isEmpty { return "md5:\(md5)" }
        return "name:\(displayName)|\(platform)"
    }
}
