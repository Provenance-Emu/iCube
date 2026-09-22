// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Wire types for the pairing and trusted-peer auth routes. `Data` fields ride
/// as base64 strings (Codable's JSON default), the same convention at both
/// ends.
public enum ContinuityPairingMessages {

    public struct PairStartRequest: Codable, Sendable {
        public var peerId: String
        public var name: String
        public var publicKey: Data

        public init(peerId: String, name: String, publicKey: Data) {
            self.peerId = peerId
            self.name = name
            self.publicKey = publicKey
        }
    }

    public struct PairStartResponse: Codable, Sendable {
        public var pairingId: String
        public var serverId: String
        public var serverName: String
        public var serverPublicKey: Data

        public init(pairingId: String, serverId: String, serverName: String, serverPublicKey: Data) {
            self.pairingId = pairingId
            self.serverId = serverId
            self.serverName = serverName
            self.serverPublicKey = serverPublicKey
        }
    }

    public struct PairCompleteRequest: Codable, Sendable {
        public var pairingId: String
        public var proof: Data

        public init(pairingId: String, proof: Data) {
            self.pairingId = pairingId
            self.proof = proof
        }
    }

    public struct AuthStartRequest: Codable, Sendable {
        public var peerId: String

        public init(peerId: String) {
            self.peerId = peerId
        }
    }

    public struct AuthStartResponse: Codable, Sendable {
        public var authId: String
        public var serverId: String
        public var nonce: Data

        public init(authId: String, serverId: String, nonce: Data) {
            self.authId = authId
            self.serverId = serverId
            self.nonce = nonce
        }
    }

    public struct AuthCompleteRequest: Codable, Sendable {
        public var authId: String
        public var peerId: String
        public var signature: Data

        public init(authId: String, peerId: String, signature: Data) {
            self.authId = authId
            self.peerId = peerId
            self.signature = signature
        }
    }

    /// Terminal success payload for `pair/complete` and `auth/complete`: the
    /// active session's bearer token.
    public struct SessionTokenResponse: Codable, Sendable {
        public var sessionToken: String

        public init(sessionToken: String) {
            self.sessionToken = sessionToken
        }
    }
}
