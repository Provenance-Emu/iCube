// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import XCTest
@testable import PVContinuity

// MARK: - Pairing math

final class PairingMathTests: XCTestCase {

    private func transcript(
        pairingId: String = "p1",
        clientId: String = "c1",
        serverId: String = "s1",
        clientKey: Data = Data([1, 2, 3]),
        serverKey: Data = Data([4, 5, 6])
    ) -> Data {
        ContinuityPairingMath.pairingTranscript(
            pairingId: pairingId, clientId: clientId, serverId: serverId,
            clientPublicKey: clientKey, serverPublicKey: serverKey
        )
    }

    func testPairingCodeIsSixDigitsZeroPadded() {
        for _ in 0..<500 {
            let code = ContinuityPairingMath.makePairingCode()
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(code.allSatisfy(\.isNumber))
        }
    }

    func testAValidProofVerifies() {
        let t = transcript()
        let proof = ContinuityPairingMath.pairingProof(code: "123456", transcript: t)
        XCTAssertTrue(ContinuityPairingMath.verifyPairingProof(proof, code: "123456", transcript: t))
    }

    func testTheWrongCodeFails() {
        let t = transcript()
        let proof = ContinuityPairingMath.pairingProof(code: "123456", transcript: t)
        XCTAssertFalse(ContinuityPairingMath.verifyPairingProof(proof, code: "123457", transcript: t))
    }

    func testEveryTranscriptFieldIsBoundIntoTheProof() {
        // A proof must not survive the substitution of ANY identity field — a
        // relay attack works precisely by swapping one of them.
        let base = transcript()
        let proof = ContinuityPairingMath.pairingProof(code: "000000", transcript: base)

        let mutations = [
            transcript(pairingId: "p2"),
            transcript(clientId: "c2"),
            transcript(serverId: "s2"),
            transcript(clientKey: Data([9, 9, 9])),
            transcript(serverKey: Data([9, 9, 9]))
        ]
        for mutated in mutations {
            XCTAssertFalse(
                ContinuityPairingMath.verifyPairingProof(proof, code: "000000", transcript: mutated)
            )
        }
    }

    func testTranscriptCarriesAVersionPrefix() {
        XCTAssertTrue(
            String(decoding: transcript(), as: UTF8.self).hasPrefix("icube-continuity-pair-v1|")
        )
    }

    func testNoncesAreThirtyTwoBytesAndDistinct() {
        let a = ContinuityPairingMath.makeNonce()
        let b = ContinuityPairingMath.makeNonce()
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
    }

    func testAuthSignatureVerifies() throws {
        let key = Curve25519.Signing.PrivateKey()
        let nonce = ContinuityPairingMath.makeNonce()
        let signature = try ContinuityPairingMath.signAuth(
            nonce: nonce, peerId: "peer", serverId: "server", signingKey: key
        )
        XCTAssertTrue(ContinuityPairingMath.verifyAuth(
            signature: signature, nonce: nonce, peerId: "peer", serverId: "server",
            publicKey: key.publicKey.rawRepresentation
        ))
    }

    func testAnAuthSignatureCannotBeRelayedToAnotherServer() {
        let key = Curve25519.Signing.PrivateKey()
        let nonce = ContinuityPairingMath.makeNonce()
        let signature = try! ContinuityPairingMath.signAuth(
            nonce: nonce, peerId: "peer", serverId: "server-a", signingKey: key
        )
        XCTAssertFalse(ContinuityPairingMath.verifyAuth(
            signature: signature, nonce: nonce, peerId: "peer", serverId: "server-b",
            publicKey: key.publicKey.rawRepresentation
        ))
    }

    func testAnAuthSignatureIsBoundToItsNonce() {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try! ContinuityPairingMath.signAuth(
            nonce: ContinuityPairingMath.makeNonce(), peerId: "p", serverId: "s", signingKey: key
        )
        XCTAssertFalse(ContinuityPairingMath.verifyAuth(
            signature: signature, nonce: ContinuityPairingMath.makeNonce(),
            peerId: "p", serverId: "s", publicKey: key.publicKey.rawRepresentation
        ))
    }

    func testAMalformedPublicKeyIsRejectedRatherThanCrashing() {
        XCTAssertFalse(ContinuityPairingMath.verifyAuth(
            signature: Data([0]), nonce: Data([0]), peerId: "p", serverId: "s",
            publicKey: Data([1, 2, 3])
        ))
    }
}

// MARK: - Bearer tokens

final class BearerTokenValidatorTests: XCTestCase {

    func testMintedTokensAreLongAndURLSafe() {
        let token = BearerTokenValidator.mintToken()
        XCTAssertGreaterThanOrEqual(token.count, 40)
        XCTAssertFalse(token.contains("+"))
        XCTAssertFalse(token.contains("/"))
        XCTAssertFalse(token.contains("="))
    }

    func testMintedTokensAreDistinct() {
        XCTAssertNotEqual(BearerTokenValidator.mintToken(), BearerTokenValidator.mintToken())
    }

    func testTheCorrectTokenValidates() {
        let token = BearerTokenValidator.mintToken()
        XCTAssertTrue(BearerTokenValidator(token: token).validate(authorizationHeader: "Bearer \(token)"))
    }

    func testAMissingHeaderIsRejected() {
        XCTAssertFalse(BearerTokenValidator(token: "t").validate(authorizationHeader: nil))
    }

    func testAHeaderWithoutTheBearerSchemeIsRejected() {
        XCTAssertFalse(BearerTokenValidator(token: "t").validate(authorizationHeader: "t"))
        XCTAssertFalse(BearerTokenValidator(token: "t").validate(authorizationHeader: "Basic t"))
    }

    func testAPrefixOfTheTokenIsRejected() {
        let token = BearerTokenValidator.mintToken()
        let validator = BearerTokenValidator(token: token)
        XCTAssertFalse(validator.validate(authorizationHeader: "Bearer \(token.dropLast())"))
    }

    func testTheEmptyTokenDoesNotOpenTheDoor() {
        // A redacted Bonjour advertisement carries an empty token string; it
        // must never validate against a real session.
        let validator = BearerTokenValidator(token: BearerTokenValidator.mintToken())
        XCTAssertFalse(validator.validate(authorizationHeader: "Bearer "))
    }
}

// MARK: - Trust store

final class FileTrustStoreTests: XCTestCase {

    private func makeStore() -> (FileTrustStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("trust.json")
        return (FileTrustStore(fileURL: url), url)
    }

    private func peer(_ id: String) -> TrustedPeer {
        TrustedPeer(id: id, name: "Device \(id)", publicKey: Data([1, 2, 3]))
    }

    func testAddAndLookUp() async {
        let (store, _) = makeStore()
        await store.add(peer("a"))
        let found = await store.peer(withId: "a")
        XCTAssertEqual(found?.id, "a")
    }

    func testUnknownPeerIsNil() async {
        let (store, _) = makeStore()
        let found = await store.peer(withId: "nope")
        XCTAssertNil(found)
    }

    func testReAddingAPeerReplacesRatherThanDuplicates() async {
        let (store, _) = makeStore()
        await store.add(peer("a"))
        await store.add(TrustedPeer(id: "a", name: "Renamed", publicKey: Data([9])))
        let all = await store.allPeers()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "Renamed")
    }

    func testNewestPeerSortsFirst() async {
        let (store, _) = makeStore()
        await store.add(peer("a"))
        await store.add(peer("b"))
        let all = await store.allPeers()
        XCTAssertEqual(all.map(\.id), ["b", "a"])
    }

    func testRevocationTakesEffectImmediately() async {
        let (store, _) = makeStore()
        await store.add(peer("a"))
        await store.removePeer(withId: "a")
        let found = await store.peer(withId: "a")
        XCTAssertNil(found, "a revoked peer must be gone on the very next read")
    }

    func testRemoveAll() async {
        let (store, _) = makeStore()
        await store.add(peer("a"))
        await store.add(peer("b"))
        await store.removeAll()
        let all = await store.allPeers()
        XCTAssertTrue(all.isEmpty)
    }

    func testTrustSurvivesAFreshStoreOverTheSameFile() async {
        let (store, url) = makeStore()
        await store.add(peer("a"))
        let reopened = FileTrustStore(fileURL: url)
        let found = await reopened.peer(withId: "a")
        XCTAssertEqual(found?.id, "a")
    }

    func testAMissingFileReadsAsAnEmptyStoreRatherThanThrowing() async {
        let (store, _) = makeStore()
        let all = await store.allPeers()
        XCTAssertTrue(all.isEmpty)
    }

    func testOnlyPublicKeyMaterialIsPersisted() async throws {
        let (store, url) = makeStore()
        let identity = ContinuityPeerIdentity(name: "Mine")
        await store.add(identity.asTrustedPeer())

        let raw = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([TrustedPeer].self, from: raw)
        XCTAssertEqual(decoded.first?.publicKey, identity.publicKeyData)

        // Foundation's JSONEncoder escapes "/" in base64, so check both forms
        // rather than only the unescaped one (which would pass vacuously for
        // any key whose base64 happens to contain a slash).
        let text = String(decoding: raw, as: UTF8.self)
        let privateB64 = identity.privateKeyData.base64EncodedString()
        XCTAssertFalse(text.contains(privateB64), "the private key must never reach the trust file")
        XCTAssertFalse(
            text.contains(privateB64.replacingOccurrences(of: "/", with: "\\/")),
            "the private key must never reach the trust file"
        )
    }
}

// MARK: - Peer identity

final class ContinuityPeerIdentityTests: XCTestCase {

    func testAnIdentityRoundTripsThroughItsPrivateKeyData() throws {
        let original = ContinuityPeerIdentity(name: "Apple TV")
        let restored = try ContinuityPeerIdentity(
            id: original.id, name: original.name, privateKeyData: original.privateKeyData
        )
        XCTAssertEqual(restored.publicKeyData, original.publicKeyData)
    }

    func testCorruptKeyMaterialThrowsRatherThanSilentlyMintingANewIdentity() {
        // Silently generating a fresh key would un-pair every peer with no
        // signal that anything had happened.
        XCTAssertThrowsError(
            try ContinuityPeerIdentity(id: "x", name: "y", privateKeyData: Data([1, 2, 3]))
        )
    }
}

// MARK: - Library grants

final class FileLibraryGrantStoreTests: XCTestCase {

    private func makeStore() -> FileLibraryGrantStore {
        FileLibraryGrantStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathComponent("grants.json")
        )
    }

    func testGrantsRoundTrip() async {
        let store = makeStore()
        await store.setGrant(.everything, forPeerId: "a")
        let grant = await store.grant(forPeerId: "a")
        XCTAssertEqual(grant, .everything)
    }

    func testADeniedGrantIsRememberedRatherThanAbsent() async {
        // "Don't Share" must persist; an absent grant means "never asked",
        // which would re-prompt forever.
        let store = makeStore()
        await store.setGrant(.denied, forPeerId: "a")
        let grant = await store.grant(forPeerId: "a")
        XCTAssertEqual(grant, .denied)
    }

    func testAnUnknownPeerHasNoGrant() async {
        let store = makeStore()
        let grant = await store.grant(forPeerId: "nobody")
        XCTAssertNil(grant, "nil must mean 'never asked', distinct from .denied")
    }

    func testAllGrantsListsEveryDecisionSoTheOwnerCanUndoThem() async {
        let store = makeStore()
        await store.setGrant(.denied, forPeerId: "a")
        await store.setGrant(.askPerGame, forPeerId: "b")
        let all = await store.allGrants()
        XCTAssertEqual(all, ["a": .denied, "b": .askPerGame])
    }

    func testRemovingAGrantRestoresTheNeverAskedState() async {
        let store = makeStore()
        await store.setGrant(.denied, forPeerId: "a")
        await store.removeGrant(forPeerId: "a")
        let grant = await store.grant(forPeerId: "a")
        XCTAssertNil(grant)
    }

    func testGrantsAreSeparateFromTrust() async {
        // A denied peer is remembered here WITHOUT becoming a trusted peer —
        // trust-store membership is what authorises pulls.
        let grants = makeStore()
        await grants.setGrant(.denied, forPeerId: "a")

        let trust = FileTrustStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathComponent("t.json")
        )
        let trusted = await trust.peer(withId: "a")
        XCTAssertNil(trusted)
    }
}
