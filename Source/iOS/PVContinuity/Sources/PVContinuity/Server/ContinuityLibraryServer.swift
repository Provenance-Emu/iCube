// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Foundation
import PVWebServer

/// The serving side of nearby library sharing: catalog, artwork, per-entry
/// manifest and file routes, gated by the per-peer grant store.
///
/// ## Why this is not `ContinuitySessionServer`
///
/// Two structural reasons, both of which would be bugs if this rode on the
/// session server instead:
///
///   * **There is no session.** `ContinuitySessionServer.authorize` answers
///     `404` whenever `session == nil`, which is correct for handoff — a peer
///     holding a stale URL should stop and re-discover. A host that shares its
///     library is not playing anything, so under that rule every library
///     request would 404 forever.
///   * **Grants are per-peer, so the server must know who is asking.**
///     `BearerTokenValidator` holds one token and compares SHA-256 digests; it
///     has no notion of identity. So this actor keeps its own registry of
///     peer-scoped tokens, minted by its own auth exchange, and every route
///     resolves a token to a `peerId` before it does anything else.
///
/// ## Revocation
///
/// Trust is consulted **live** on every single request, never cached, which is
/// what makes "forget this device" take effect on that device's very next
/// request rather than at next launch. `forgetPeer` additionally drops the
/// peer's token and any cached pull approvals, so an in-flight ranged download
/// stops too.
public actor ContinuityLibraryServer {

    /// How long a library token stays valid without use. Long enough to browse
    /// a library and pull a disc image over a slow network; short enough that a
    /// token left behind by a peer that wandered off stops working.
    public static let tokenLifetime: TimeInterval = 60 * 60
    /// The per-pull approval prompt is a human decision, same shape as pairing.
    public static let approvalTimeout: TimeInterval = 120
    /// Cap on tokens held at once, so a LAN flooder cannot grow the registry
    /// without bound. Pruning happens first, so this only bites on genuinely
    /// concurrent peers.
    static let maxActiveTokens = 16

    /// What a peer with no recorded grant gets.
    ///
    /// `.askPerGame`, not `.denied`: a peer the owner deliberately paired has
    /// been approved as a device already, and the control point for *copying a
    /// game* is the per-pull prompt. Defaulting to `.denied` would mean a
    /// freshly paired device silently sees nothing, with no prompt to explain
    /// why and nothing in the review list to undo.
    public static let defaultGrant: ContinuityLibraryGrant = .askPerGame

    private struct IssuedToken {
        let peerId: String
        let peerName: String
        let expiresAt: Date
    }

    private struct PendingAuth {
        let peerId: String
        let nonce: Data
        let expiresAt: Date
    }

    private let identity: ContinuityPeerIdentity
    private let libraryProvider: any ContinuityLibraryProviding
    private let trustStore: any ContinuityTrustStore
    private let grantStore: any ContinuityLibraryGrantStore
    private let approver: any ContinuityLibraryPullApproving
    private let sourceDevice: SourceDevice
    /// Whether this device shares its library at all. A closure, not a stored
    /// flag, so turning the switch off in Settings takes effect on the next
    /// request instead of at next launch — the same reason the trust store is
    /// consulted live.
    private let sharesLibraryProvider: @Sendable () async -> Bool

    /// Keyed by the token's SHA-256 hex, never by the token itself, so the
    /// registry holds no material that is directly replayable if it is ever
    /// dumped — the same reasoning as `BearerTokenValidator`'s digest compare.
    private var tokens: [String: IssuedToken] = [:]
    private var pendingAuths: [String: PendingAuth] = [:]
    /// `peerId|entryKey` pairs the owner has approved for this run.
    ///
    /// Needed because one logical pull is many HTTP requests: a disc image is
    /// fetched with `Range` and resumed after any drop. Prompting per request
    /// would put a dialog on screen dozens of times for one transfer, which is
    /// the fastest way to teach someone to tap Allow without reading.
    private var approvedPulls: Set<String> = []
    private var routesRegistered = false

    public init(
        identity: ContinuityPeerIdentity,
        libraryProvider: any ContinuityLibraryProviding,
        trustStore: any ContinuityTrustStore,
        grantStore: any ContinuityLibraryGrantStore,
        approver: any ContinuityLibraryPullApproving,
        sourceDevice: SourceDevice,
        sharesLibraryProvider: @escaping @Sendable () async -> Bool
    ) {
        self.identity = identity
        self.libraryProvider = libraryProvider
        self.trustStore = trustStore
        self.grantStore = grantStore
        self.approver = approver
        self.sourceDevice = sourceDevice
        self.sharesLibraryProvider = sharesLibraryProvider
    }

    // MARK: - Route registration

    /// Registers the library routes. Call once at server setup; safe to call
    /// again (no-op).
    public func activate(on registrar: any WebRouteRegistering) {
        guard !routesRegistered else { return }
        routesRegistered = true

        registrar.addAsyncHandler(forMethod: "POST", path: ContinuityRoutes.libraryAuthStart) { [weak self] request in
            await self?.handleAuthStart(request) ?? .error(status: 404, message: "unavailable")
        }
        registrar.addAsyncHandler(forMethod: "POST", path: ContinuityRoutes.libraryAuthComplete) { [weak self] request in
            await self?.handleAuthComplete(request) ?? .error(status: 404, message: "unavailable")
        }
        registrar.addAsyncHandler(forMethod: "GET", path: ContinuityRoutes.libraryCatalog) { [weak self] request in
            await self?.handleCatalog(request) ?? .error(status: 404, message: "unavailable")
        }
        registrar.addAsyncHandler(forMethod: "GET", path: ContinuityRoutes.libraryArtwork) { [weak self] request in
            await self?.handleArtwork(request) ?? .error(status: 404, message: "unavailable")
        }
        registrar.addAsyncHandler(forMethod: "GET", path: ContinuityRoutes.libraryManifest) { [weak self] request in
            await self?.handleManifest(request) ?? .error(status: 404, message: "unavailable")
        }
        registrar.addAsyncHandler(forMethod: "GET", path: ContinuityRoutes.libraryFile) { [weak self] request in
            await self?.handleFile(request) ?? .error(status: 404, message: "unavailable")
        }
    }

    // MARK: - Revocation

    /// Drops everything cached about a peer.
    ///
    /// Called when the owner forgets the device or sets `.denied`. Dropping the
    /// token as well as the approvals is what stops an **in-flight** transfer:
    /// the next Range request in the sequence authenticates afresh and fails.
    public func forgetPeer(_ peerId: String) {
        tokens = tokens.filter { $0.value.peerId != peerId }
        pendingAuths = pendingAuths.filter { $0.value.peerId != peerId }
        approvedPulls = approvedPulls.filter { !$0.hasPrefix("\(peerId)|") }
    }

    /// Drops every token and approval. For "forget all devices".
    public func forgetAllPeers() {
        tokens.removeAll()
        pendingAuths.removeAll()
        approvedPulls.removeAll()
    }

    // MARK: - Auth

    private func handleAuthStart(_ request: WebRouteRequest) async -> WebRouteResponse {
        guard await sharesLibraryProvider() else {
            return .error(status: 403, message: "this device isn't sharing its library")
        }
        guard let body: ContinuityPairingMessages.AuthStartRequest = decode(request) else {
            return .error(status: 400, message: "invalid auth request")
        }
        // Denial is checked before trust on purpose: a remembered "no" has to
        // hold whether or not the peer is still paired, and grant-store
        // membership is deliberately separate from trust-store membership so
        // that remembering "no" never implies granting access.
        if await grant(for: body.peerId) == .denied {
            return .error(status: 403, message: "library sharing is turned off for this device")
        }
        guard await trustStore.peer(withId: body.peerId) != nil else {
            return .error(status: 403, message: "not a paired device")
        }
        pruneAuths()

        let authId = UUID().uuidString
        let nonce = ContinuityPairingMath.makeNonce()
        pendingAuths[authId] = PendingAuth(
            peerId: body.peerId,
            nonce: nonce,
            expiresAt: Date().addingTimeInterval(ContinuityPairingServer.authLifetime)
        )
        return encode(ContinuityPairingMessages.AuthStartResponse(
            authId: authId, serverId: identity.id, nonce: nonce
        ))
    }

    private func handleAuthComplete(_ request: WebRouteRequest) async -> WebRouteResponse {
        guard await sharesLibraryProvider() else {
            return .error(status: 403, message: "this device isn't sharing its library")
        }
        guard let body: ContinuityPairingMessages.AuthCompleteRequest = decode(request) else {
            return .error(status: 400, message: "invalid auth completion")
        }
        // Single-use: consumed however verification goes, so a failed attempt
        // cannot be replayed against the same challenge.
        guard let pending = pendingAuths.removeValue(forKey: body.authId),
              pending.expiresAt > Date(),
              pending.peerId == body.peerId else {
            return .error(status: 410, message: "auth challenge expired or unknown")
        }
        guard let peer = await trustStore.peer(withId: body.peerId),
              ContinuityPairingMath.verifyAuth(
                signature: body.signature,
                nonce: pending.nonce,
                peerId: peer.id,
                serverId: identity.id,
                publicKey: peer.publicKey
              ) else {
            return .error(status: 403, message: "signature verification failed")
        }
        if await grant(for: peer.id) == .denied {
            return .error(status: 403, message: "library sharing is turned off for this device")
        }

        pruneTokens()
        guard tokens.count < Self.maxActiveTokens else {
            return .error(status: 429, message: "too many devices browsing at once")
        }
        let token = BearerTokenValidator.mintToken()
        tokens[Self.digestHex(of: token)] = IssuedToken(
            peerId: peer.id,
            peerName: peer.name,
            expiresAt: Date().addingTimeInterval(Self.tokenLifetime)
        )
        return encode(ContinuityLibraryMessages.LibraryTokenResponse(libraryToken: token))
    }

    // MARK: - Authorisation

    /// Resolves a request's bearer token to the peer behind it, or returns the
    /// denial to send back.
    ///
    /// Every library route starts here. The order matters and is the same
    /// everywhere: sharing off → token → live trust → `.denied` grant.
    private func authorizedPeer(_ request: WebRouteRequest) async -> Authorization {
        guard await sharesLibraryProvider() else {
            return .denied(.error(status: 403, message: "this device isn't sharing its library"))
        }
        guard let token = Self.bearerToken(from: request.header("Authorization")) else {
            return .denied(.error(status: 401, message: "missing library token"))
        }
        pruneTokens()
        guard let issued = tokens[Self.digestHex(of: token)] else {
            return .denied(.error(status: 401, message: "invalid or expired library token"))
        }
        // Live, every request — this is what makes revoke immediate.
        guard await trustStore.peer(withId: issued.peerId) != nil else {
            forgetPeer(issued.peerId)
            return .denied(.error(status: 403, message: "not a paired device"))
        }
        if await grant(for: issued.peerId) == .denied {
            forgetPeer(issued.peerId)
            return .denied(.error(status: 403, message: "library sharing is turned off for this device"))
        }
        return .allowed(issued)
    }

    /// Either the peer behind the request, or the response to send instead.
    /// A two-case enum rather than `Result` because `WebRouteResponse` is a
    /// perfectly good denial and a thoroughly bad `Error`.
    private enum Authorization {
        case allowed(IssuedToken)
        case denied(WebRouteResponse)
    }

    /// `.everything` and `.askPerGame` both browse **silently**. Only a pull
    /// distinguishes them — see the doc comment on `ContinuityLibraryGrant` for
    /// why re-consenting to every browse is actively harmful rather than
    /// merely noisy.
    private func grant(for peerId: String) async -> ContinuityLibraryGrant {
        await grantStore.grant(forPeerId: peerId) ?? Self.defaultGrant
    }

    // MARK: - Browse routes

    private func handleCatalog(_ request: WebRouteRequest) async -> WebRouteResponse {
        switch await authorizedPeer(request) {
        case .denied(let denial): return denial
        case .allowed: break
        }
        do {
            return .json(try await builder().catalog().encoded())
        } catch {
            return .error(status: 500, message: "catalog build failed: \(error)")
        }
    }

    private func handleArtwork(_ request: WebRouteRequest) async -> WebRouteResponse {
        switch await authorizedPeer(request) {
        case .denied(let denial): return denial
        case .allowed: break
        }
        guard let key = request.query[ContinuityRoutes.libraryKeyQueryKey], !key.isEmpty else {
            return .error(status: 400, message: "missing ?\(ContinuityRoutes.libraryKeyQueryKey)=")
        }
        // Artwork is gated by exclusion too. A cover is a strong hint that the
        // owner has the game, which is exactly what excluding it was meant to
        // stop leaking.
        guard await !libraryProvider.isExcludedFromSharing(key: key),
              let png = await libraryProvider.artworkPNG(forKey: key) else {
            return .error(status: 404, message: "no artwork for that entry")
        }
        return WebRouteResponse(status: 200, contentType: "image/png", body: .data(png))
    }

    private func handleManifest(_ request: WebRouteRequest) async -> WebRouteResponse {
        switch await authorizedPeer(request) {
        case .denied(let denial): return denial
        case .allowed: break
        }
        guard let key = request.query[ContinuityRoutes.libraryKeyQueryKey], !key.isEmpty else {
            return .error(status: 400, message: "missing ?\(ContinuityRoutes.libraryKeyQueryKey)=")
        }
        guard let manifest = await builder().manifest(forKey: key, sessionId: key) else {
            // Excluded and unknown are one answer on purpose: see
            // `ContinuityLibraryManifestBuilder.manifest(forKey:sessionId:)`.
            return .error(status: 404, message: "no such game")
        }
        do {
            return .json(try manifest.encoded())
        } catch {
            return .error(status: 500, message: "manifest encode failed: \(error)")
        }
    }

    // MARK: - Pull route

    private func handleFile(_ request: WebRouteRequest) async -> WebRouteResponse {
        let issued: IssuedToken
        switch await authorizedPeer(request) {
        case .denied(let denial): return denial
        case .allowed(let token): issued = token
        }
        guard let key = request.query[ContinuityRoutes.libraryKeyQueryKey], !key.isEmpty else {
            return .error(status: 400, message: "missing ?\(ContinuityRoutes.libraryKeyQueryKey)=")
        }
        guard let relativePath = request.query[ContinuityRoutes.filePathQueryKey], !relativePath.isEmpty else {
            return .error(status: 400, message: "missing ?\(ContinuityRoutes.filePathQueryKey)=")
        }

        // Re-derive the manifest from the key rather than trusting anything the
        // client remembered. This is the check that makes "an excluded game
        // 404s if requested directly by path" true: exclusion is re-read here,
        // so a peer holding a relative path from before the owner excluded the
        // game gets nothing.
        guard let manifest = await builder().manifest(forKey: key, sessionId: key) else {
            return .error(status: 404, message: "no such game")
        }
        // Whole-string equality against the manifest's own list, exactly as the
        // handoff file route does: no prefix test, no sandbox test, nothing to
        // get subtly wrong.
        guard let descriptor = manifest.descriptor(forRelativePath: relativePath) else {
            return .error(status: 404, message: "not part of that game")
        }

        guard await approvePull(issued: issued, key: key, gameName: manifest.game.displayName) else {
            return .error(status: 403, message: "the other device declined this copy")
        }

        do {
            let url = try await libraryProvider.fileURL(for: descriptor)
            if let range = ByteRangeRequest.parse(header: request.header("Range")) {
                guard let length = range.length(totalSize: descriptor.size),
                      let contentRange = range.contentRange(totalSize: descriptor.size) else {
                    return .error(status: 416, message: "range not satisfiable")
                }
                return WebRouteResponse(
                    status: 206,
                    contentType: "application/octet-stream",
                    headers: ["Content-Range": contentRange, "Accept-Ranges": "bytes"],
                    body: .file(url: url, offset: range.offset, length: length)
                )
            }
            return WebRouteResponse(
                status: 200,
                contentType: "application/octet-stream",
                headers: ["Accept-Ranges": "bytes"],
                body: .file(url: url, offset: 0, length: nil)
            )
        } catch {
            return .error(status: 404, message: "file unavailable: \(error)")
        }
    }

    /// Enforces the grant on a pull, prompting once per peer+game for
    /// `.askPerGame`.
    private func approvePull(issued: IssuedToken, key: String, gameName: String) async -> Bool {
        switch await grant(for: issued.peerId) {
        case .denied:
            return false
        case .everything:
            return true
        case .askPerGame:
            break
        }

        let approvalKey = "\(issued.peerId)|\(key)"
        if approvedPulls.contains(approvalKey) { return true }

        let decision = await Self.withTimeout(Self.approvalTimeout) { [approver] in
            await approver.approveLibraryPull(peerName: issued.peerName, gameName: gameName)
        } ?? .denyOnce

        switch decision {
        case .allowOnce:
            approvedPulls.insert(approvalKey)
            return true
        case .allowAlways:
            approvedPulls.insert(approvalKey)
            await grantStore.setGrant(.everything, forPeerId: issued.peerId)
            return true
        case .denyOnce:
            return false
        case .denyAlways:
            await grantStore.setGrant(.denied, forPeerId: issued.peerId)
            forgetPeer(issued.peerId)
            return false
        }
    }

    // MARK: - Helpers

    private func builder() -> ContinuityLibraryManifestBuilder {
        ContinuityLibraryManifestBuilder(libraryProvider: libraryProvider, sourceDevice: sourceDevice)
    }

    /// Extracts the token from an `Authorization: Bearer <token>` header.
    static func bearerToken(from header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let prefix = "Bearer "
        guard trimmed.count > prefix.count,
              trimmed.prefix(prefix.count).lowercased() == prefix.lowercased() else { return nil }
        let token = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    static func digestHex(of token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func pruneTokens() {
        let now = Date()
        tokens = tokens.filter { $0.value.expiresAt > now }
    }

    private func pruneAuths() {
        let now = Date()
        pendingAuths = pendingAuths.filter { $0.value.expiresAt > now }
    }

    /// nil on timeout. The losing task is not force-killed — an approval prompt
    /// awaiting a SwiftUI continuation cannot be cancelled meaningfully, so a
    /// late answer is simply dropped.
    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ body: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func decode<T: Decodable>(_ request: WebRouteRequest) -> T? {
        guard let body = request.body else { return nil }
        return try? JSONDecoder().decode(T.self, from: body)
    }

    private func encode<T: Encodable>(_ payload: T) -> WebRouteResponse {
        guard let data = try? JSONEncoder().encode(payload) else {
            return .error(status: 500, message: "encoding failed")
        }
        return .json(data)
    }

    // MARK: - Test seams

    /// Number of live tokens. Test-only.
    var activeTokenCount: Int {
        tokens.count
    }
}
