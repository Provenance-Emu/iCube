// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The client half of pairing and trusted-peer auth.
///
/// Both flows end in a session bearer token. `authenticate` is tried first
/// (silent, no user interaction); pairing is the fallback when this device is
/// not yet trusted by the peer.
public actor ContinuityPairingClient {
    /// How long to keep polling `pair/complete` for the other user's answer.
    /// Matches the server's pairing lifetime — polling longer only produces
    /// `410`s.
    public static let approvalPollTimeout: TimeInterval = ContinuityPairingServer.pairingLifetime
    /// Poll interval. Fast enough that an approval feels immediate, slow enough
    /// that a two-minute wait is ~120 requests rather than thousands.
    public static let approvalPollInterval: TimeInterval = 1.0

    private let identity: ContinuityPeerIdentity
    private let transport: any ContinuityTransport

    public init(identity: ContinuityPeerIdentity, transport: any ContinuityTransport) {
        self.identity = identity
        self.transport = transport
    }

    // MARK: - Trusted-peer auth (silent)

    /// Proves possession of the paired private key and returns the peer's
    /// session token. Throws `ContinuityError.notPaired` when this device is
    /// not in the peer's trust store — the caller's signal to fall back to
    /// `pair(with:code:)`.
    public func authenticate(baseURL: URL) async throws -> String {
        let startResponse = try await transport.request(
            try .json(
                url: baseURL.appendingPathComponent(ContinuityRoutes.authStart),
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
                url: baseURL.appendingPathComponent(ContinuityRoutes.authComplete),
                payload: ContinuityPairingMessages.AuthCompleteRequest(
                    authId: challenge.authId, peerId: identity.id, signature: signature
                )
            )
        )
        switch completeResponse.status {
        case 200:
            return try completeResponse.decoded(ContinuityPairingMessages.SessionTokenResponse.self).sessionToken
        case 403: throw ContinuityError.notPaired
        case 404: throw ContinuityError.noActiveSession
        case 410: throw ContinuityError.pairingExpired
        default: throw ContinuityError.invalidResponse(status: completeResponse.status)
        }
    }

    // MARK: - Pairing

    /// Begins pairing. The peer shows a 6-digit code; the returned handle is
    /// what `completePairing` needs once the user has typed it in.
    ///
    /// Split into begin/complete rather than taking the code up front because
    /// the code does not exist until this call has been made — the server
    /// generates it and puts it on the other device's screen in response.
    public func beginPairing(baseURL: URL) async throws -> PairingHandle {
        let response = try await transport.request(
            try .json(
                url: baseURL.appendingPathComponent(ContinuityRoutes.pairStart),
                payload: ContinuityPairingMessages.PairStartRequest(
                    peerId: identity.id, name: identity.name, publicKey: identity.publicKeyData
                )
            )
        )
        switch response.status {
        case 200: break
        case 429: throw ContinuityError.invalidResponse(status: 429)
        default: throw ContinuityError.invalidResponse(status: response.status)
        }
        let started = try response.decoded(ContinuityPairingMessages.PairStartResponse.self)
        return PairingHandle(
            pairingId: started.pairingId,
            serverId: started.serverId,
            serverName: started.serverName,
            serverPublicKey: started.serverPublicKey,
            baseURL: baseURL
        )
    }

    /// Submits the code the user read off the other device's screen and polls
    /// until they approve, decline, or the pairing expires.
    ///
    /// A `202` means "the other user hasn't answered yet" and is the only
    /// status worth retrying; `401` (wrong code) is returned to the caller
    /// immediately so the UI can say so while the code is still live and the
    /// user still has attempts left.
    public func completePairing(_ handle: PairingHandle, code: String) async throws -> String {
        let transcript = ContinuityPairingMath.pairingTranscript(
            pairingId: handle.pairingId,
            clientId: identity.id,
            serverId: handle.serverId,
            clientPublicKey: identity.publicKeyData,
            serverPublicKey: handle.serverPublicKey
        )
        let proof = ContinuityPairingMath.pairingProof(code: code, transcript: transcript)
        let request = try ContinuityRequest.json(
            url: handle.baseURL.appendingPathComponent(ContinuityRoutes.pairComplete),
            payload: ContinuityPairingMessages.PairCompleteRequest(pairingId: handle.pairingId, proof: proof)
        )

        let deadline = Date().addingTimeInterval(Self.approvalPollTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let response = try await transport.request(request)
            switch response.status {
            case 200:
                return try response.decoded(ContinuityPairingMessages.SessionTokenResponse.self).sessionToken
            case 202:
                try await Task.sleep(nanoseconds: UInt64(Self.approvalPollInterval * 1_000_000_000))
                continue
            case 401:
                throw ContinuityError.tokenRejected
            case 403:
                throw ContinuityError.pairingDeclined
            case 410:
                throw ContinuityError.pairingExpired
            case 404:
                throw ContinuityError.noActiveSession
            default:
                throw ContinuityError.invalidResponse(status: response.status)
            }
        }
        throw ContinuityError.pairingExpired
    }

    /// An in-flight pairing: everything `completePairing` needs to rebuild the
    /// transcript, so the caller only has to supply the code.
    public struct PairingHandle: Sendable {
        public var pairingId: String
        public var serverId: String
        public var serverName: String
        public var serverPublicKey: Data
        public var baseURL: URL
    }
}
