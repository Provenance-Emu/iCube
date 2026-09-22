// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVWebServer

/// Everything a caller needs in order to advertise a freshly opened session.
public struct ContinuitySessionInfo: Sendable, Equatable {
    public var sessionId: String
    public var token: String
    public var game: GameIdentity

    public init(sessionId: String, token: String, game: GameIdentity) {
        self.sessionId = sessionId
        self.token = token
        self.game = game
    }
}

/// The serving side of a handoff: owns the session token and answers the
/// manifest / mint / file routes on the app's existing web server.
///
/// Routes are registered **once**, at app setup, and then answer `404` while no
/// session is active and `401` without the current session's bearer token.
/// Registering per-session would mean the route table grew every time a user
/// handed a game off, and `WebRouteTable` refuses duplicates anyway.
public actor ContinuitySessionServer {
    private let fileProvider: any ContinuityFileProviding
    private let minter: any SaveStateMinting
    private let sourceDevice: SourceDevice

    private var validator: BearerTokenValidator?
    private var session: ContinuitySessionInfo?
    private var saveState: SaveStateDescriptor?
    /// The manifest most recently built for the live session. It doubles as the
    /// file route's allow-list, so a client cannot widen what it may fetch by
    /// asking for a differently-shaped manifest.
    private var currentManifest: ContinuityManifest?
    private var routesRegistered = false

    public init(
        fileProvider: any ContinuityFileProviding,
        minter: any SaveStateMinting,
        sourceDevice: SourceDevice
    ) {
        self.fileProvider = fileProvider
        self.minter = minter
        self.sourceDevice = sourceDevice
    }

    // MARK: - Session lifecycle

    /// Mints a token and opens a session for `game`.
    ///
    /// A second call **replaces** the session and invalidates the previous
    /// token, so a user who starts a handoff, changes their mind, and starts
    /// another does not leave a live token behind for the first one.
    public func beginSession(game: GameIdentity) -> ContinuitySessionInfo {
        let token = BearerTokenValidator.mintToken()
        let info = ContinuitySessionInfo(sessionId: UUID().uuidString, token: token, game: game)
        validator = BearerTokenValidator(token: token)
        session = info
        saveState = nil
        currentManifest = nil
        return info
    }

    public func endSession() {
        validator = nil
        session = nil
        saveState = nil
        currentManifest = nil
    }

    public var isSessionActive: Bool { session != nil }

    /// The live session's token — what the pairing/auth routes hand to an
    /// approved peer. nil when no session is open.
    public var activeToken: String? { session?.token }

    public var activeGame: GameIdentity? { session?.game }

    // MARK: - Route registration

    /// Registers the session routes. Call once at server setup; safe to call
    /// again (no-op).
    public func activate(on registrar: any WebRouteRegistering) {
        guard !routesRegistered else { return }
        routesRegistered = true

        registrar.addAsyncHandler(forMethod: "GET", path: ContinuityRoutes.manifest) { [weak self] request in
            await self?.handleManifest(request) ?? .error(status: 404, message: "no session")
        }
        registrar.addAsyncHandler(forMethod: "POST", path: ContinuityRoutes.mint) { [weak self] request in
            await self?.handleMint(request) ?? .error(status: 404, message: "no session")
        }
        registrar.addAsyncHandler(forMethod: "GET", path: ContinuityRoutes.file) { [weak self] request in
            await self?.handleFile(request) ?? .error(status: 404, message: "no session")
        }
    }

    // MARK: - Handlers

    /// Returns a denial response, or nil when the request may proceed.
    ///
    /// `404` for "no session" and `401` for "bad token" are distinct on
    /// purpose: a client that gets 404 should stop and re-discover, while 401
    /// means re-authenticate. Collapsing them would make the client's retry
    /// logic guess.
    private func authorize(_ request: WebRouteRequest) -> WebRouteResponse? {
        guard session != nil, let validator else {
            return .error(status: 404, message: "no active handoff session")
        }
        guard validator.validate(authorizationHeader: request.header("Authorization")) else {
            return .error(status: 401, message: "invalid or missing session token")
        }
        return nil
    }

    private func handleManifest(_ request: WebRouteRequest) async -> WebRouteResponse {
        if let denial = authorize(request) { return denial }
        do {
            let manifest = try await buildManifest()
            return .json(try manifest.encoded())
        } catch {
            return .error(status: 500, message: "manifest build failed: \(error)")
        }
    }

    private func handleMint(_ request: WebRouteRequest) async -> WebRouteResponse {
        if let denial = authorize(request) { return denial }
        guard let session else { return .error(status: 404, message: "no active handoff session") }
        do {
            saveState = try await minter.mintHandoffState(identity: session.game)
            // The freshly minted state changes the payload, so the cached
            // manifest (and with it the file route's allow-list) must be
            // rebuilt — otherwise a client that fetched the manifest before
            // minting would be handed a manifest naming a state it is then
            // forbidden to download.
            currentManifest = nil
            let manifest = try await buildManifest()
            return .json(try manifest.encoded())
        } catch {
            return .error(status: 500, message: "save state mint failed: \(error)")
        }
    }

    private func handleFile(_ request: WebRouteRequest) async -> WebRouteResponse {
        if let denial = authorize(request) { return denial }
        guard let relativePath = request.query[ContinuityRoutes.filePathQueryKey], !relativePath.isEmpty else {
            return .error(status: 400, message: "missing ?\(ContinuityRoutes.filePathQueryKey)=")
        }

        // The manifest IS the allow-list. Only a path it already describes can
        // be served, so no crafted `?path=` — traversal, absolute, or simply
        // someone else's save — can reach outside this session's payload. Note
        // that this is a whole-string equality check against a list, not a
        // prefix or sandbox test; there is nothing to get subtly wrong.
        let manifest: ContinuityManifest
        do {
            manifest = try await buildManifest()
        } catch {
            return .error(status: 500, message: "manifest build failed: \(error)")
        }
        guard let descriptor = manifest.descriptor(forRelativePath: relativePath) else {
            return .error(status: 404, message: "not part of this session")
        }

        do {
            let url = try await fileProvider.fileURL(for: descriptor)
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

    // MARK: - Manifest assembly

    /// Builds (and caches for the session) the manifest.
    ///
    /// The cache is what makes the file route's allow-list stable: two calls
    /// during one session describe the same payload, so a file that was
    /// fetchable when the client read the manifest is still fetchable when it
    /// gets round to asking for it. `beginSession` and `handleMint` invalidate
    /// it, which are exactly the two moments the payload legitimately changes.
    private func buildManifest() async throws -> ContinuityManifest {
        if let currentManifest { return currentManifest }
        guard let session else { throw ContinuityError.noActiveSession }
        let manifest = try await ContinuityManifestBuilder(
            fileProvider: fileProvider, sourceDevice: sourceDevice
        ).build(
            game: session.game,
            sessionId: session.sessionId,
            saveState: saveState
        )
        currentManifest = manifest
        return manifest
    }
}
