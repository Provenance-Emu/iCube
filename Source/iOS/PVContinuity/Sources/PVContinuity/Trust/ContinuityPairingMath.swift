// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Foundation

/// Pure crypto for the pairing and trusted-peer auth handshakes. Side-effect
/// free, so every operation is unit-testable and both endpoints share one
/// definition of what is being signed.
///
/// ## Threat model — what this does and does not buy you
///
/// **What pairing gives you:** it raises the bar from "anything that can read a
/// Bonjour TXT record on this network" to "a device whose user was physically
/// looking at a 6-digit code on this screen, and whom this user approved". The
/// proof is an HMAC-SHA256 keyed on the code digest over a transcript that
/// binds the pairing id and *both* devices' Curve25519 public keys, so it
/// cannot be relayed to a third device. Trusted-peer auth afterwards proves
/// possession of the paired private key by signing a single-use server nonce.
///
/// **What it does not give you: confidentiality.** Traffic is plain HTTP on the
/// local network. Save states, memory cards, Wii saves and disc images cross
/// the LAN in the clear and are readable by anything else on it. Pairing
/// authenticates the peer; it adds no encryption whatsoever.
///
/// This is an accepted tradeoff, carried over deliberately from iFly, and it is
/// stated in the pairing and settings UI rather than left for a user to
/// discover. It is not something to "fix later by adding a token" — a token
/// changes who may ask, never who may read. Closing it means TLS.
public enum ContinuityPairingMath {

    /// Uniformly random 6-digit, zero-padded display code.
    public static func makePairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    /// The canonical transcript both sides bind the proof to.
    ///
    /// Every identity field plus both public keys go in, so a mismatch
    /// anywhere — wrong pairing id, substituted key, a relayed proof aimed at a
    /// different server — breaks the HMAC rather than being silently accepted.
    /// The version prefix means a future transcript shape can never be
    /// confused with this one.
    public static func pairingTranscript(
        pairingId: String,
        clientId: String,
        serverId: String,
        clientPublicKey: Data,
        serverPublicKey: Data
    ) -> Data {
        var transcript = Data("icube-continuity-pair-v1|".utf8)
        transcript += Data("\(pairingId)|\(clientId)|\(serverId)|".utf8)
        transcript += clientPublicKey
        transcript += Data("|".utf8)
        transcript += serverPublicKey
        return transcript
    }

    /// Proof that the client's user read the code off the server's screen.
    public static func pairingProof(code: String, transcript: Data) -> Data {
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data(code.utf8))))
        return Data(HMAC<SHA256>.authenticationCode(for: transcript, using: key))
    }

    /// Constant-time proof check.
    public static func verifyPairingProof(_ proof: Data, code: String, transcript: Data) -> Bool {
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data(code.utf8))))
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: transcript, using: key)
    }

    /// Single-use random auth nonce.
    public static func makeNonce() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }

    /// What a trusted peer signs to claim a session: the nonce bound to both
    /// identities, so a captured signature cannot be replayed at another server.
    public static func authMessage(nonce: Data, peerId: String, serverId: String) -> Data {
        var message = Data("icube-continuity-auth-v1|".utf8)
        message += Data("\(peerId)|\(serverId)|".utf8)
        message += nonce
        return message
    }

    public static func signAuth(
        nonce: Data, peerId: String, serverId: String,
        signingKey: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        try signingKey.signature(for: authMessage(nonce: nonce, peerId: peerId, serverId: serverId))
    }

    public static func verifyAuth(
        signature: Data, nonce: Data, peerId: String, serverId: String,
        publicKey: Data
    ) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return key.isValidSignature(
            signature,
            for: authMessage(nonce: nonce, peerId: peerId, serverId: serverId)
        )
    }
}
