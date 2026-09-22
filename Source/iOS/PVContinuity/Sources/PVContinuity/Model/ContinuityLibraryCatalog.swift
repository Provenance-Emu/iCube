// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One title a host offers to browsing peers.
///
/// Deliberately thin. A catalog is browsed before any pull is approved, so it
/// is the part of nearby sharing a peer sees **cheapest** — and therefore the
/// part that must carry the least. It names the game and says how big it is;
/// it says nothing about how the owner has played it. No save-state count, no
/// last-played date, no play time: those are facts about the person, not the
/// title, and a browse is not consent to hand them over.
public struct ContinuityLibraryEntry: Codable, Hashable, Sendable, Identifiable {
    /// `GameIdentity.stableKey` of `game` — the handle every other library
    /// route addresses this entry by.
    public var key: String
    public var game: GameIdentity
    /// Size of the disc image, so a peer can see what a pull would cost before
    /// starting one.
    public var sizeBytes: Int64
    /// Whether `ContinuityRoutes.libraryArtwork` will return cover art for this
    /// key, so a browser can show a placeholder immediately rather than firing
    /// a request per entry to find out.
    public var hasArtwork: Bool

    public var id: String { key }

    public init(key: String, game: GameIdentity, sizeBytes: Int64, hasArtwork: Bool) {
        self.key = key
        self.game = game
        self.sizeBytes = sizeBytes
        self.hasArtwork = hasArtwork
    }

    /// Builds an entry whose key is derived from the identity, so the two can
    /// never disagree about what addresses what.
    public init(game: GameIdentity, sizeBytes: Int64, hasArtwork: Bool) {
        self.init(key: game.stableKey, game: game, sizeBytes: sizeBytes, hasArtwork: hasArtwork)
    }
}

/// What a host serves at `ContinuityRoutes.libraryCatalog`.
///
/// Versioned and checked during decode, exactly like `ContinuityManifest`: a
/// peer that doesn't understand a catalog says so rather than rendering a
/// partially-parsed list that looks like the host owns three games.
public struct ContinuityLibraryCatalog: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let supportedVersions: ClosedRange<Int> = 1...1

    public var version: Int
    public var sourceDevice: SourceDevice
    /// Already filtered: anything the owner excluded from nearby sharing is
    /// absent, not flagged. See `ContinuityLibraryManifestBuilder`.
    public var entries: [ContinuityLibraryEntry]

    public init(
        version: Int = ContinuityLibraryCatalog.currentVersion,
        sourceDevice: SourceDevice,
        entries: [ContinuityLibraryEntry]
    ) {
        self.version = version
        self.sourceDevice = sourceDevice
        self.entries = entries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard Self.supportedVersions.contains(version) else {
            throw ContinuityError.manifestVersionUnsupported(found: version)
        }
        self.version = version
        self.sourceDevice = try container.decode(SourceDevice.self, forKey: .sourceDevice)
        self.entries = try container.decode([ContinuityLibraryEntry].self, forKey: .entries)
    }

    public func entry(forKey key: String) -> ContinuityLibraryEntry? {
        entries.first { $0.key == key }
    }

    // MARK: - Wire codec

    /// Same ISO-8601 + sorted-keys convention as `ContinuityManifest`, so two
    /// devices on different locales produce byte-identical catalogs for
    /// identical content.
    public static func decode(from data: Data) throws -> ContinuityLibraryCatalog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ContinuityLibraryCatalog.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// Wire types for the library auth exchange.
///
/// The exchange is the trusted-peer one from `ContinuityPairingServer` —
/// nonce, Curve25519 signature, live trust-store lookup — differing only in
/// what it returns. It is a separate route family because the token it mints
/// is **peer-scoped**: grants are per-peer, so the server has to be able to
/// answer "who is this?" on every subsequent request, which a single shared
/// session token structurally cannot do.
public enum ContinuityLibraryMessages {
    /// Terminal success payload for `library/auth/complete`.
    public struct LibraryTokenResponse: Codable, Sendable {
        public var libraryToken: String

        public init(libraryToken: String) {
            self.libraryToken = libraryToken
        }
    }
}
