// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The browsing side of nearby library sharing.
///
/// Authenticates with the peer-scoped library token (a separate exchange from
/// the handoff session token — see `ContinuityRoutes`), then fetches the
/// catalog, artwork and per-entry manifests. The actual transfer is handed to
/// `ContinuityPuller`, unchanged: a library pull is a manifest pull like any
/// other once the manifest is in hand, and duplicating the resume/verify logic
/// is how the two would drift.
///
/// This device must already be **paired** with the peer. There is no pairing
/// fallback here on purpose: pairing shows a 6-digit code on the other device's
/// screen, and a browse is not the moment to make somebody walk across a room.
/// The caller pairs first (the handoff flow already does), then browses.
public actor ContinuityLibraryClient {

    private let identity: ContinuityPeerIdentity
    private let transport: any ContinuityTransport
    /// Cached per base URL so a browse followed by a pull is one auth exchange,
    /// not two. Dropped on any `401`/`403`, which is how a revocation on the
    /// host turns into a clean failure here rather than a silent retry loop.
    private var tokensByHost: [URL: String] = [:]

    public init(identity: ContinuityPeerIdentity, transport: any ContinuityTransport) {
        self.identity = identity
        self.transport = transport
    }

    // MARK: - Auth

    /// Obtains (or reuses) a library token for `baseURL`.
    ///
    /// Throws `ContinuityError.notPaired` when the host does not know this
    /// device, and — importantly — the **same** error when the host has the
    /// peer marked `.denied` or has library sharing switched off. The host
    /// deliberately does not distinguish those cases on the wire; telling a
    /// peer "you specifically are blocked" is information the owner did not
    /// agree to share.
    public func token(for baseURL: URL) async throws -> String {
        if let cached = tokensByHost[baseURL] { return cached }

        let startResponse = try await transport.request(
            try .json(
                url: baseURL.appendingPathComponent(ContinuityRoutes.libraryAuthStart),
                payload: ContinuityPairingMessages.AuthStartRequest(peerId: identity.id)
            )
        )
        switch startResponse.status {
        case 200: break
        case 403: throw ContinuityError.notPaired
        default: throw ContinuityError.invalidResponse(status: startResponse.status)
        }
        let challenge = try startResponse.decoded(ContinuityPairingMessages.AuthStartResponse.self)

        let signature = try ContinuityPairingMath.signAuth(
            nonce: challenge.nonce,
            peerId: identity.id,
            serverId: challenge.serverId,
            signingKey: identity.signingKey
        )
        let completeResponse = try await transport.request(
            try .json(
                url: baseURL.appendingPathComponent(ContinuityRoutes.libraryAuthComplete),
                payload: ContinuityPairingMessages.AuthCompleteRequest(
                    authId: challenge.authId, peerId: identity.id, signature: signature
                )
            )
        )
        switch completeResponse.status {
        case 200: break
        case 403: throw ContinuityError.notPaired
        case 410: throw ContinuityError.pairingExpired
        default: throw ContinuityError.invalidResponse(status: completeResponse.status)
        }
        let token = try completeResponse
            .decoded(ContinuityLibraryMessages.LibraryTokenResponse.self).libraryToken
        tokensByHost[baseURL] = token
        return token
    }

    /// Forgets the cached token for a host, so the next call re-authenticates.
    public func invalidateToken(for baseURL: URL) {
        tokensByHost[baseURL] = nil
    }

    // MARK: - Browsing

    public func catalog(from baseURL: URL) async throws -> ContinuityLibraryCatalog {
        let data = try await get(
            url: ContinuityRoutes.libraryCatalogURL(base: baseURL), baseURL: baseURL
        )
        return try ContinuityLibraryCatalog.decode(from: data)
    }

    /// Cover art PNG, or nil when the host has none for that entry. A missing
    /// cover is a placeholder in the browse list, never an error the user sees.
    public func artwork(from baseURL: URL, key: String) async -> Data? {
        let url = ContinuityRoutes.libraryURL(
            base: baseURL, path: ContinuityRoutes.libraryArtwork, key: key
        )
        return try? await get(url: url, baseURL: baseURL)
    }

    /// The manifest for one entry. A `404` here means the owner excluded the
    /// game (or never had it); the two are not distinguishable by design.
    public func manifest(from baseURL: URL, key: String) async throws -> ContinuityManifest {
        let url = ContinuityRoutes.libraryURL(
            base: baseURL, path: ContinuityRoutes.libraryManifest, key: key
        )
        let data = try await get(url: url, baseURL: baseURL)
        return try ContinuityManifest.decode(from: data)
    }

    /// A `ContinuityPuller` wired to this host's library file route.
    ///
    /// The library file route addresses a file by **entry key plus path**, not
    /// by path alone, because the host re-checks the entry's exclusion before
    /// serving a byte. So the puller is handed a URL builder that carries both.
    public func puller(
        forKey key: String,
        fileProvider: any ContinuityFileProviding
    ) -> ContinuityPuller {
        ContinuityPuller(
            transport: transport,
            fileProvider: fileProvider,
            fileURLBuilder: { base, relativePath in
                ContinuityRoutes.libraryFileURL(base: base, key: key, relativePath: relativePath)
            }
        )
    }

    // MARK: - Helpers

    private func get(url: URL, baseURL: URL) async throws -> Data {
        let token = try await token(for: baseURL)
        let response = try await transport.request(.authorized(url: url, token: token))
        switch response.status {
        case 200:
            return response.body
        case 401:
            // The host no longer honours this token. Drop it so the caller's
            // retry re-authenticates instead of replaying a dead one.
            tokensByHost[baseURL] = nil
            throw ContinuityError.tokenRejected
        case 403:
            tokensByHost[baseURL] = nil
            throw ContinuityError.notPaired
        case 404:
            throw ContinuityError.invalidResponse(status: 404)
        default:
            throw ContinuityError.invalidResponse(status: response.status)
        }
    }
}
