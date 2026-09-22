// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Route paths for the continuity API, shared by server and client so the two
/// can never drift.
public enum ContinuityRoutes {
    // MARK: Handoff session
    public static let manifest = "/api/continuity/manifest"
    public static let mint = "/api/continuity/mint"
    public static let file = "/api/continuity/file"

    // MARK: Pairing + trusted-peer auth. All POST, JSON bodies.
    public static let pairStart = "/api/continuity/pair/start"
    public static let pairComplete = "/api/continuity/pair/complete"
    public static let authStart = "/api/continuity/auth/start"
    public static let authComplete = "/api/continuity/auth/complete"

    // MARK: Nearby library browsing
    //
    // A deliberately separate route family from the handoff session above, for
    // two reasons that are easy to lose:
    //
    //   * **There is no session.** A host that shares its library is not
    //     playing anything. The session routes answer `404` while no session is
    //     open, which is the correct answer *for them* and exactly the wrong
    //     one here.
    //   * **The server has to know WHICH peer is asking.** Handoff's
    //     `BearerTokenValidator` holds one token and compares digests; it has
    //     no notion of identity, and per-peer grants are meaningless without
    //     one. So library access has its own token registry, keyed by peer,
    //     minted by its own auth exchange below.
    //
    // The library auth exchange reuses the pairing signature scheme verbatim
    // (`ContinuityPairingMath.verifyAuth` over a single-use server nonce); only
    // the token it hands back differs.
    public static let libraryAuthStart = "/api/continuity/library/auth/start"
    public static let libraryAuthComplete = "/api/continuity/library/auth/complete"
    /// The shared game list. GET, bearer library token.
    public static let libraryCatalog = "/api/continuity/library/catalog"
    /// Cover art for one entry, as PNG bytes. GET `?key=`.
    public static let libraryArtwork = "/api/continuity/library/art"
    /// The manifest for one entry — the disc image and nothing of the owner's.
    /// GET `?key=`.
    public static let libraryManifest = "/api/continuity/library/manifest"
    /// One file of a library manifest. GET `?key=` + `?path=`.
    public static let libraryFile = "/api/continuity/library/file"

    public static let filePathQueryKey = "path"
    /// Identifies a catalog entry. The value is `GameIdentity.stableKey`.
    public static let libraryKeyQueryKey = "key"

    /// URL for pulling one descriptor of a session manifest.
    public static func fileURL(base: URL, relativePath: String) -> URL {
        var components = URLComponents(
            url: base.appendingPathComponent(file), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: filePathQueryKey, value: relativePath)]
        return components?.url ?? base
    }

    public static func manifestURL(base: URL) -> URL {
        base.appendingPathComponent(manifest)
    }

    public static func mintURL(base: URL) -> URL {
        base.appendingPathComponent(mint)
    }

    public static func libraryCatalogURL(base: URL) -> URL {
        base.appendingPathComponent(libraryCatalog)
    }

    /// URL for a library route that addresses one catalog entry.
    public static func libraryURL(base: URL, path: String, key: String) -> URL {
        var components = URLComponents(
            url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: libraryKeyQueryKey, value: key)]
        return components?.url ?? base
    }

    /// URL for one file of a library manifest. Both the entry key **and** the
    /// path travel, because the server re-derives (and re-checks the exclusion
    /// of) that entry's manifest before it will serve a byte — an excluded game
    /// must 404 even when the caller already knows the relative path.
    public static func libraryFileURL(base: URL, key: String, relativePath: String) -> URL {
        var components = URLComponents(
            url: base.appendingPathComponent(libraryFile), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: libraryKeyQueryKey, value: key),
            URLQueryItem(name: filePathQueryKey, value: relativePath)
        ]
        return components?.url ?? base
    }
}
