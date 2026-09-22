// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Foundation

/// A device the user explicitly paired with — the unit of cross-device trust.
///
/// Only the **public** key is stored. Nothing in this record is secret, which
/// is why a plain JSON file is an adequate home for it.
public struct TrustedPeer: Codable, Hashable, Sendable, Identifiable {
    /// Stable peer-chosen identifier, one per app install.
    public var id: String
    public var name: String
    /// Raw-representation Curve25519 verifying key.
    public var publicKey: Data
    public var addedAt: Date

    public init(id: String, name: String, publicKey: Data, addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
        self.addedAt = addedAt
    }
}

/// This device's long-term pairing identity.
///
/// The kit never persists the private key: the host passes `privateKeyData`
/// back in from wherever it decided key custody belongs (Keychain, a protected
/// file), so that decision stays the app's and is visible at the call site.
public struct ContinuityPeerIdentity: Sendable {
    public let id: String
    public let name: String
    public let signingKey: Curve25519.Signing.PrivateKey

    public var publicKeyData: Data { signingKey.publicKey.rawRepresentation }
    public var privateKeyData: Data { signingKey.rawRepresentation }

    /// Fresh identity (first launch).
    public init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
        self.signingKey = Curve25519.Signing.PrivateKey()
    }

    /// Restored identity from host-persisted key material.
    public init(id: String, name: String, privateKeyData: Data) throws {
        self.id = id
        self.name = name
        self.signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
    }

    public func asTrustedPeer() -> TrustedPeer {
        TrustedPeer(id: id, name: name, publicKey: publicKeyData)
    }
}

/// Persistence seam for paired peers.
///
/// Revocation has to take effect immediately, which is why every read is a
/// live call rather than a snapshot handed to the server at activation: the
/// pairing server consults the store on each auth attempt, so removing a peer
/// locks it out of the very next request.
public protocol ContinuityTrustStore: Sendable {
    func peer(withId id: String) async -> TrustedPeer?
    func allPeers() async -> [TrustedPeer]
    func add(_ peer: TrustedPeer) async
    func removePeer(withId id: String) async
    func removeAll() async
}

/// JSON-file trust store, newest first.
///
/// Plain storage is deliberate: the file holds only public keys and display
/// names. A host that wants Keychain semantics implements the protocol itself
/// rather than this type growing a mode switch.
public actor FileTrustStore: ContinuityTrustStore {
    private let fileURL: URL
    private var cached: [TrustedPeer]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func peer(withId id: String) -> TrustedPeer? {
        load().first { $0.id == id }
    }

    public func allPeers() -> [TrustedPeer] {
        load()
    }

    public func add(_ peer: TrustedPeer) {
        var peers = load().filter { $0.id != peer.id }
        peers.insert(peer, at: 0)
        save(peers)
    }

    public func removePeer(withId id: String) {
        save(load().filter { $0.id != id })
    }

    public func removeAll() {
        save([])
    }

    private func load() -> [TrustedPeer] {
        if let cached { return cached }
        let peers = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([TrustedPeer].self, from: $0) } ?? []
        cached = peers
        return peers
    }

    private func save(_ peers: [TrustedPeer]) {
        // The in-memory cache is updated first and unconditionally. A failed
        // write must still revoke for this app session — the alternative is a
        // "Revoke" button that appears to work and doesn't.
        cached = peers
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(peers)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A silently-failing trust write is a security-UX trap: loud in
            // debug, degrade to session-only trust in release.
            assertionFailure("FileTrustStore write failed: \(error)")
        }
    }
}
