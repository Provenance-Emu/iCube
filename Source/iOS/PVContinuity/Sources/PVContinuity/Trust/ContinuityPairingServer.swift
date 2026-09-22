// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVWebServer

/// Server side of cross-device trust.
///
/// Two flows, both ending in the same thing — the active session's bearer token:
///   * **Pairing**, once per peer: code-verified and user-approved.
///   * **Trusted-peer auth**, every time after: a signature over a single-use
///     server nonce, no prompt.
///
/// ## Flow shape, and why it polls
///
/// `pair/start` returns **immediately** and the approval prompt runs in a
/// detached task; `pair/complete` answers `202` while approval is pending and
/// the client polls. Holding the HTTP request open for the length of a human
/// decision would tie a socket to a person's attention span, and the server
/// this rides on is the same one serving file transfers.
///
/// Codes expire after `pairingLifetime`, proofs get `maxProofAttempts` tries
/// (so a 6-digit code is not brute-forceable across a session), and nonces are
/// consumed on first use whatever the verification result.
public actor ContinuityPairingServer {
    /// A pairing code is on screen for a human to read out. Two minutes is long
    /// enough to walk across a room and short enough that a code left on a
    /// screen stops being useful.
    public static let pairingLifetime: TimeInterval = 120
    /// An auth nonce is consumed by a machine within one round trip.
    public static let authLifetime: TimeInterval = 30
    /// 3 tries over a 6-digit space, per code, with the code dying afterwards.
    public static let maxProofAttempts = 3
    /// In-flight pairing cap, so a LAN flooder cannot queue unbounded prompts
    /// at the user.
    static let maxPendingPairings = 3

    private struct PendingPairing {
        let clientId: String
        let clientName: String
        let clientPublicKey: Data
        let code: String
        let expiresAt: Date
        var attemptsLeft: Int
        var approval: Approval = .pending

        enum Approval { case pending, approved, denied }
    }

    private struct PendingAuth {
        let peerId: String
        let nonce: Data
        let expiresAt: Date
    }

    private let identity: ContinuityPeerIdentity
    private let trustStore: any ContinuityTrustStore
    private let approver: any ContinuityPairingApproving
    /// The live session's token, or nil when nothing is being served. Read
    /// through a closure rather than held, so revoking a session takes effect
    /// on the very next handout.
    private let sessionTokenProvider: @Sendable () async -> String?

    private var pendingPairings: [String: PendingPairing] = [:]
    private var pendingAuths: [String: PendingAuth] = [:]
    private var routesRegistered = false

    public init(
        identity: ContinuityPeerIdentity,
        trustStore: any ContinuityTrustStore,
        approver: any ContinuityPairingApproving,
        sessionTokenProvider: @escaping @Sendable () async -> String?
    ) {
        self.identity = identity
        self.trustStore = trustStore
        self.approver = approver
        self.sessionTokenProvider = sessionTokenProvider
    }

    /// Registers the pairing/auth routes. Call once at server setup; safe to
    /// call again (no-op).
    public func activate(on registrar: any WebRouteRegistering) {
        guard !routesRegistered else { return }
        routesRegistered = true

        registrar.addAsyncHandler(forMethod: "POST", path: ContinuityRoutes.pairStart) { [weak self] request in
            await self?.handlePairStart(request) ?? .error(status: 404, message: "unavailable")
        }
        registrar.addAsyncHandler(forMethod: "POST", path: ContinuityRoutes.pairComplete) { [weak self] request in
            await self?.handlePairComplete(request) ?? .error(status: 404, message: "unavailable")
        }
        registrar.addAsyncHandler(forMethod: "POST", path: ContinuityRoutes.authStart) { [weak self] request in
            await self?.handleAuthStart(request) ?? .error(status: 404, message: "unavailable")
        }
        registrar.addAsyncHandler(forMethod: "POST", path: ContinuityRoutes.authComplete) { [weak self] request in
            await self?.handleAuthComplete(request) ?? .error(status: 404, message: "unavailable")
        }
    }

    // MARK: - Pairing

    private func handlePairStart(_ request: WebRouteRequest) async -> WebRouteResponse {
        guard let body: ContinuityPairingMessages.PairStartRequest = decode(request) else {
            return .error(status: 400, message: "invalid pairing request")
        }
        prunePending()
        guard pendingPairings.count < Self.maxPendingPairings else {
            return .error(status: 429, message: "too many pairing attempts in flight")
        }

        let pairingId = UUID().uuidString
        let code = ContinuityPairingMath.makePairingCode()
        pendingPairings[pairingId] = PendingPairing(
            clientId: body.peerId,
            clientName: body.name,
            clientPublicKey: body.publicKey,
            code: code,
            expiresAt: Date().addingTimeInterval(Self.pairingLifetime),
            attemptsLeft: Self.maxProofAttempts
        )

        // The prompt runs off this request's lifetime, raced against the
        // pairing lifetime. A host UI that cannot present, or a user who never
        // answers, must not park the approver forever — if it did, every FUTURE
        // pairing request would be auto-declined by a prompt nobody can see.
        Task { [approver] in
            let approved = await Self.withTimeout(Self.pairingLifetime) {
                await approver.approvePairing(peerName: body.name, code: code)
            } ?? false
            await self.resolveApproval(pairingId: pairingId, approved: approved)
        }

        return encode(ContinuityPairingMessages.PairStartResponse(
            pairingId: pairingId,
            serverId: identity.id,
            serverName: identity.name,
            serverPublicKey: identity.publicKeyData
        ))
    }

    private func resolveApproval(pairingId: String, approved: Bool) {
        guard var pending = pendingPairings[pairingId] else { return }
        pending.approval = approved ? .approved : .denied
        pendingPairings[pairingId] = pending
    }

    private func handlePairComplete(_ request: WebRouteRequest) async -> WebRouteResponse {
        guard let body: ContinuityPairingMessages.PairCompleteRequest = decode(request) else {
            return .error(status: 400, message: "invalid pairing completion")
        }
        guard var pending = pendingPairings[body.pairingId], pending.expiresAt > Date() else {
            pendingPairings[body.pairingId] = nil
            return .error(status: 410, message: "pairing expired or unknown")
        }

        switch pending.approval {
        case .pending:
            return .error(status: 202, message: "waiting for approval on the other device")
        case .denied:
            pendingPairings[body.pairingId] = nil
            return .error(status: 403, message: "pairing was declined")
        case .approved:
            break
        }

        let transcript = ContinuityPairingMath.pairingTranscript(
            pairingId: body.pairingId,
            clientId: pending.clientId,
            serverId: identity.id,
            clientPublicKey: pending.clientPublicKey,
            serverPublicKey: identity.publicKeyData
        )
        guard ContinuityPairingMath.verifyPairingProof(body.proof, code: pending.code, transcript: transcript) else {
            pending.attemptsLeft -= 1
            if pending.attemptsLeft <= 0 {
                pendingPairings[body.pairingId] = nil
                return .error(status: 410, message: "too many bad codes — start pairing again")
            }
            pendingPairings[body.pairingId] = pending
            // 401 is retryable (wrong code, try again); 403 above is terminal
            // (the user said no). A client must be able to tell them apart.
            return .error(status: 401, message: "wrong code")
        }

        pendingPairings[body.pairingId] = nil
        await trustStore.add(TrustedPeer(
            id: pending.clientId,
            name: pending.clientName,
            publicKey: pending.clientPublicKey
        ))
        return await sessionTokenResponse()
    }

    // MARK: - Trusted-peer auth

    private func handleAuthStart(_ request: WebRouteRequest) async -> WebRouteResponse {
        guard let body: ContinuityPairingMessages.AuthStartRequest = decode(request) else {
            return .error(status: 400, message: "invalid auth request")
        }
        // The trust store is consulted live, every time — which is what makes
        // "revoke" take effect immediately rather than at next launch.
        guard await trustStore.peer(withId: body.peerId) != nil else {
            return .error(status: 403, message: "not a paired device")
        }
        pruneAuths()

        let authId = UUID().uuidString
        let nonce = ContinuityPairingMath.makeNonce()
        pendingAuths[authId] = PendingAuth(
            peerId: body.peerId,
            nonce: nonce,
            expiresAt: Date().addingTimeInterval(Self.authLifetime)
        )
        return encode(ContinuityPairingMessages.AuthStartResponse(
            authId: authId, serverId: identity.id, nonce: nonce
        ))
    }

    private func handleAuthComplete(_ request: WebRouteRequest) async -> WebRouteResponse {
        guard let body: ContinuityPairingMessages.AuthCompleteRequest = decode(request) else {
            return .error(status: 400, message: "invalid auth completion")
        }
        // Single-use: the nonce is consumed however verification goes, so a
        // failed attempt cannot be retried against the same challenge.
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
        return await sessionTokenResponse()
    }

    // MARK: - Helpers

    private func sessionTokenResponse() async -> WebRouteResponse {
        guard let token = await sessionTokenProvider() else {
            return .error(status: 404, message: "no active handoff session")
        }
        return encode(ContinuityPairingMessages.SessionTokenResponse(sessionToken: token))
    }

    private func prunePending() {
        let now = Date()
        pendingPairings = pendingPairings.filter { $0.value.expiresAt > now }
    }

    private func pruneAuths() {
        let now = Date()
        pendingAuths = pendingAuths.filter { $0.value.expiresAt > now }
    }

    /// nil on timeout.
    ///
    /// The losing task is not force-killed: an approval prompt awaiting a
    /// SwiftUI continuation cannot be cancelled meaningfully. A late answer is
    /// simply dropped, and `resolveApproval` on an already-pruned pairing id
    /// no-ops.
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

    /// The code currently displayed for a pending pairing. Test-only: the code
    /// is otherwise known solely to the approval prompt and the user reading it.
    func pendingCode(forPairingId id: String) -> String? {
        pendingPairings[id]?.code
    }
}
