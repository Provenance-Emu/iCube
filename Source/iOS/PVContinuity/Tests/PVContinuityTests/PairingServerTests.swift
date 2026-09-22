// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import PVWebServer
import PVContinuityTesting
@testable import PVContinuity

final class PairingServerTests: XCTestCase {

    private struct Fixture {
        let server: ContinuityPairingServer
        let registrar: MockRouteRegistrar
        let trust: FileTrustStore
        let identity: ContinuityPeerIdentity
        let approver: MockPairingApprover
        let token: String
    }

    private func makeFixture(approves: Bool = true, hangs: Bool = false, sessionToken: String? = "live-token") async -> Fixture {
        let identity = ContinuityPeerIdentity(name: "Apple TV")
        let trust = FileTrustStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathComponent("trust.json")
        )
        let approver = MockPairingApprover(answer: approves, hangs: hangs)
        let server = ContinuityPairingServer(
            identity: identity,
            trustStore: trust,
            approver: approver,
            sessionTokenProvider: { sessionToken }
        )
        let registrar = MockRouteRegistrar()
        await server.activate(on: registrar)
        return Fixture(
            server: server, registrar: registrar, trust: trust,
            identity: identity, approver: approver, token: sessionToken ?? ""
        )
    }

    private func encode<T: Encodable>(_ value: T) -> Data { try! JSONEncoder().encode(value) }

    private func decode<T: Decodable>(_ type: T.Type, _ response: WebRouteResponse) throws -> T {
        guard case .data(let data) = response.body else {
            throw ContinuityError.invalidResponse(status: response.status)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Runs pair/start and then polls pair/complete until the detached approval
    /// task has resolved, so the test does not race the prompt.
    private func pollUntilDecided(
        _ fixture: Fixture, pairingId: String, proof: Data, attempts: Int = 200
    ) async throws -> WebRouteResponse {
        for _ in 0..<attempts {
            let response = try require(await fixture.registrar.send(
                method: "POST", path: ContinuityRoutes.pairComplete,
                body: encode(ContinuityPairingMessages.PairCompleteRequest(pairingId: pairingId, proof: proof))
            ))
            if response.status != 202 { return response }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("approval never resolved")
        throw ContinuityError.pairingExpired
    }

    private func startPairing(
        _ fixture: Fixture, client: ContinuityPeerIdentity
    ) async throws -> ContinuityPairingMessages.PairStartResponse {
        let response = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.pairStart,
            body: encode(ContinuityPairingMessages.PairStartRequest(
                peerId: client.id, name: client.name, publicKey: client.publicKeyData
            ))
        ))
        XCTAssertEqual(response.status, 200)
        return try decode(ContinuityPairingMessages.PairStartResponse.self, response)
    }

    private func proof(
        _ started: ContinuityPairingMessages.PairStartResponse,
        client: ContinuityPeerIdentity,
        code: String
    ) -> Data {
        ContinuityPairingMath.pairingProof(
            code: code,
            transcript: ContinuityPairingMath.pairingTranscript(
                pairingId: started.pairingId,
                clientId: client.id,
                serverId: started.serverId,
                clientPublicKey: client.publicKeyData,
                serverPublicKey: started.serverPublicKey
            )
        )
    }

    // MARK: - Registration

    func testActivateRegistersThePairingAndAuthRoutes() async {
        let fixture = await makeFixture()
        let registered = Set(fixture.registrar.registrations.map { "\($0.method) \($0.path)" })
        XCTAssertEqual(registered, [
            "POST \(ContinuityRoutes.pairStart)",
            "POST \(ContinuityRoutes.pairComplete)",
            "POST \(ContinuityRoutes.authStart)",
            "POST \(ContinuityRoutes.authComplete)"
        ])
    }

    func testActivateIsIdempotent() async {
        let fixture = await makeFixture()
        await fixture.server.activate(on: fixture.registrar)
        XCTAssertEqual(fixture.registrar.registrations.count, 4)
    }

    // MARK: - Pairing happy path

    func testAnApprovedPairingWithTheRightCodeYieldsTheSessionToken() async throws {
        let fixture = await makeFixture(approves: true)
        let client = ContinuityPeerIdentity(name: "iPhone")
        let started = try await startPairing(fixture, client: client)

        let code = try require(await fixture.server.pendingCode(forPairingId: started.pairingId))
        let response = try await pollUntilDecided(
            fixture, pairingId: started.pairingId, proof: proof(started, client: client, code: code)
        )
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(
            try decode(ContinuityPairingMessages.SessionTokenResponse.self, response).sessionToken,
            "live-token"
        )
    }

    func testASuccessfulPairingPersistsTheClientsPublicKey() async throws {
        let fixture = await makeFixture(approves: true)
        let client = ContinuityPeerIdentity(name: "iPhone")
        let started = try await startPairing(fixture, client: client)
        let code = try require(await fixture.server.pendingCode(forPairingId: started.pairingId))
        _ = try await pollUntilDecided(
            fixture, pairingId: started.pairingId, proof: proof(started, client: client, code: code)
        )

        let stored = await fixture.trust.peer(withId: client.id)
        XCTAssertEqual(stored?.publicKey, client.publicKeyData)
        XCTAssertEqual(stored?.name, "iPhone")
    }

    func testThePromptSeesTheCodeAndThePeerName() async throws {
        let fixture = await makeFixture(approves: true)
        let client = ContinuityPeerIdentity(name: "iPhone")
        let started = try await startPairing(fixture, client: client)
        let code = try require(await fixture.server.pendingCode(forPairingId: started.pairingId))
        _ = try await pollUntilDecided(
            fixture, pairingId: started.pairingId, proof: proof(started, client: client, code: code)
        )
        let shown = await fixture.approver.lastCode
        let name = await fixture.approver.lastPeerName
        XCTAssertEqual(shown, code)
        XCTAssertEqual(name, "iPhone")
    }

    // MARK: - Pairing failures

    func testADeclinedPairingIs403AndStoresNoTrust() async throws {
        let fixture = await makeFixture(approves: false)
        let client = ContinuityPeerIdentity(name: "iPhone")
        let started = try await startPairing(fixture, client: client)
        let code = try require(await fixture.server.pendingCode(forPairingId: started.pairingId))
        let response = try await pollUntilDecided(
            fixture, pairingId: started.pairingId, proof: proof(started, client: client, code: code)
        )
        XCTAssertEqual(response.status, 403)
        let stored = await fixture.trust.peer(withId: client.id)
        XCTAssertNil(stored)
    }

    func testAWrongCodeIs401AndIsRetryable() async throws {
        let fixture = await makeFixture(approves: true)
        let client = ContinuityPeerIdentity(name: "iPhone")
        let started = try await startPairing(fixture, client: client)
        let code = try require(await fixture.server.pendingCode(forPairingId: started.pairingId))
        let wrong = proof(started, client: client, code: code == "000000" ? "111111" : "000000")

        let bad = try await pollUntilDecided(fixture, pairingId: started.pairingId, proof: wrong)
        XCTAssertEqual(bad.status, 401, "401 is retryable; 403 would be terminal")

        let good = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.pairComplete,
            body: encode(ContinuityPairingMessages.PairCompleteRequest(
                pairingId: started.pairingId, proof: proof(started, client: client, code: code)
            ))
        ))
        XCTAssertEqual(good.status, 200)
    }

    func testTheCodeDiesAfterThreeWrongAttempts() async throws {
        let fixture = await makeFixture(approves: true)
        let client = ContinuityPeerIdentity(name: "iPhone")
        let started = try await startPairing(fixture, client: client)
        let code = try require(await fixture.server.pendingCode(forPairingId: started.pairingId))
        let wrong = proof(started, client: client, code: code == "000000" ? "111111" : "000000")

        // The first wrong proof rides the approval poll; two more finish the
        // budget. Three attempts total, the last of which kills the pairing.
        var statuses: [Int] = []
        let first = try await pollUntilDecided(fixture, pairingId: started.pairingId, proof: wrong)
        statuses.append(first.status)
        for _ in 0..<3 {
            let response = try require(await fixture.registrar.send(
                method: "POST", path: ContinuityRoutes.pairComplete,
                body: encode(ContinuityPairingMessages.PairCompleteRequest(
                    pairingId: started.pairingId, proof: wrong
                ))
            ))
            statuses.append(response.status)
        }
        XCTAssertEqual(
            statuses, [401, 401, 410, 410],
            "three tries against a six-digit code, then the pairing is gone"
        )

        // And the right code no longer helps — the pairing is gone entirely.
        let afterwards = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.pairComplete,
            body: encode(ContinuityPairingMessages.PairCompleteRequest(
                pairingId: started.pairingId, proof: proof(started, client: client, code: code)
            ))
        ))
        XCTAssertEqual(afterwards.status, 410)
    }

    func testAnUnknownPairingIdIs410() async throws {
        let fixture = await makeFixture()
        let response = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.pairComplete,
            body: encode(ContinuityPairingMessages.PairCompleteRequest(
                pairingId: "never-existed", proof: Data()
            ))
        ))
        XCTAssertEqual(response.status, 410)
    }

    func testAMalformedBodyIs400() async throws {
        let fixture = await makeFixture()
        for path in [ContinuityRoutes.pairStart, ContinuityRoutes.pairComplete,
                     ContinuityRoutes.authStart, ContinuityRoutes.authComplete] {
            let response = try require(await fixture.registrar.send(
                method: "POST", path: path, body: Data("not json".utf8)
            ))
            XCTAssertEqual(response.status, 400, "for \(path)")
        }
    }

    func testTooManyInFlightPairingsIs429() async throws {
        // A LAN flooder must not be able to queue unbounded prompts at the user.
        let fixture = await makeFixture(approves: true, hangs: true)
        for _ in 0..<ContinuityPairingServer.maxPendingPairings {
            let client = ContinuityPeerIdentity(name: "spam")
            _ = try await startPairing(fixture, client: client)
        }
        let extra = ContinuityPeerIdentity(name: "spam")
        let response = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.pairStart,
            body: encode(ContinuityPairingMessages.PairStartRequest(
                peerId: extra.id, name: extra.name, publicKey: extra.publicKeyData
            ))
        ))
        XCTAssertEqual(response.status, 429)
    }

    func testAHangingPromptStillAnswers202RatherThanBlockingTheRoute() async throws {
        // The route must not inherit the prompt's lifetime.
        let fixture = await makeFixture(approves: true, hangs: true)
        let client = ContinuityPeerIdentity(name: "iPhone")
        let started = try await startPairing(fixture, client: client)
        let response = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.pairComplete,
            body: encode(ContinuityPairingMessages.PairCompleteRequest(
                pairingId: started.pairingId, proof: Data()
            ))
        ))
        XCTAssertEqual(response.status, 202)
    }

    // MARK: - Trusted-peer auth

    private func pair(_ fixture: Fixture, client: ContinuityPeerIdentity) async throws {
        let started = try await startPairing(fixture, client: client)
        let code = try require(await fixture.server.pendingCode(forPairingId: started.pairingId))
        _ = try await pollUntilDecided(
            fixture, pairingId: started.pairingId, proof: proof(started, client: client, code: code)
        )
    }

    func testAnUnpairedPeerCannotStartAuth() async throws {
        let fixture = await makeFixture()
        let response = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.authStart,
            body: encode(ContinuityPairingMessages.AuthStartRequest(peerId: "stranger"))
        ))
        XCTAssertEqual(response.status, 403)
    }

    func testAPairedPeerAuthenticatesSilently() async throws {
        let fixture = await makeFixture(approves: true)
        let client = ContinuityPeerIdentity(name: "iPhone")
        try await pair(fixture, client: client)

        let startResponse = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.authStart,
            body: encode(ContinuityPairingMessages.AuthStartRequest(peerId: client.id))
        ))
        let challenge = try decode(ContinuityPairingMessages.AuthStartResponse.self, startResponse)

        let signature = try ContinuityPairingMath.signAuth(
            nonce: challenge.nonce, peerId: client.id, serverId: challenge.serverId,
            signingKey: client.signingKey
        )
        let completeResponse = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.authComplete,
            body: encode(ContinuityPairingMessages.AuthCompleteRequest(
                authId: challenge.authId, peerId: client.id, signature: signature
            ))
        ))
        XCTAssertEqual(completeResponse.status, 200)
        XCTAssertEqual(
            try decode(ContinuityPairingMessages.SessionTokenResponse.self, completeResponse).sessionToken,
            "live-token"
        )
    }

    func testANonceIsSingleUse() async throws {
        let fixture = await makeFixture(approves: true)
        let client = ContinuityPeerIdentity(name: "iPhone")
        try await pair(fixture, client: client)

        let startResponse = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.authStart,
            body: encode(ContinuityPairingMessages.AuthStartRequest(peerId: client.id))
        ))
        let challenge = try decode(ContinuityPairingMessages.AuthStartResponse.self, startResponse)
        let signature = try ContinuityPairingMath.signAuth(
            nonce: challenge.nonce, peerId: client.id, serverId: challenge.serverId,
            signingKey: client.signingKey
        )
        let body = encode(ContinuityPairingMessages.AuthCompleteRequest(
            authId: challenge.authId, peerId: client.id, signature: signature
        ))

        let first = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.authComplete, body: body
        ))
        XCTAssertEqual(first.status, 200)
        let replay = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.authComplete, body: body
        ))
        XCTAssertEqual(replay.status, 410, "a replayed signature must not be honoured")
    }

    func testABadSignatureConsumesTheNonceAndIsRejected() async throws {
        let fixture = await makeFixture(approves: true)
        let client = ContinuityPeerIdentity(name: "iPhone")
        try await pair(fixture, client: client)

        let startResponse = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.authStart,
            body: encode(ContinuityPairingMessages.AuthStartRequest(peerId: client.id))
        ))
        let challenge = try decode(ContinuityPairingMessages.AuthStartResponse.self, startResponse)

        let bad = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.authComplete,
            body: encode(ContinuityPairingMessages.AuthCompleteRequest(
                authId: challenge.authId, peerId: client.id, signature: Data(repeating: 0, count: 64)
            ))
        ))
        XCTAssertEqual(bad.status, 403)

        // Consumed regardless of outcome: no second bite at the same challenge.
        let retry = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.authComplete,
            body: encode(ContinuityPairingMessages.AuthCompleteRequest(
                authId: challenge.authId, peerId: client.id, signature: Data(repeating: 0, count: 64)
            ))
        ))
        XCTAssertEqual(retry.status, 410)
    }

    func testRevokingTrustTakesEffectOnTheVeryNextRequest() async throws {
        let fixture = await makeFixture(approves: true)
        let client = ContinuityPeerIdentity(name: "iPhone")
        try await pair(fixture, client: client)

        // Works before revocation.
        let before = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.authStart,
            body: encode(ContinuityPairingMessages.AuthStartRequest(peerId: client.id))
        ))
        XCTAssertEqual(before.status, 200)

        await fixture.trust.removePeer(withId: client.id)

        let after = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.authStart,
            body: encode(ContinuityPairingMessages.AuthStartRequest(peerId: client.id))
        ))
        XCTAssertEqual(after.status, 403, "revocation must not wait for a restart")
    }

    func testRevocationAlsoBlocksAnAuthAlreadyInFlight() async throws {
        let fixture = await makeFixture(approves: true)
        let client = ContinuityPeerIdentity(name: "iPhone")
        try await pair(fixture, client: client)

        let startResponse = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.authStart,
            body: encode(ContinuityPairingMessages.AuthStartRequest(peerId: client.id))
        ))
        let challenge = try decode(ContinuityPairingMessages.AuthStartResponse.self, startResponse)

        await fixture.trust.removePeer(withId: client.id)

        let signature = try ContinuityPairingMath.signAuth(
            nonce: challenge.nonce, peerId: client.id, serverId: challenge.serverId,
            signingKey: client.signingKey
        )
        let response = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.authComplete,
            body: encode(ContinuityPairingMessages.AuthCompleteRequest(
                authId: challenge.authId, peerId: client.id, signature: signature
            ))
        ))
        XCTAssertEqual(response.status, 403)
    }

    func testATokenIsNotHandedOutWhenNoSessionIsLive() async throws {
        let fixture = await makeFixture(approves: true, sessionToken: nil)
        let client = ContinuityPeerIdentity(name: "iPhone")
        let started = try await startPairing(fixture, client: client)
        let code = try require(await fixture.server.pendingCode(forPairingId: started.pairingId))
        let response = try await pollUntilDecided(
            fixture, pairingId: started.pairingId, proof: proof(started, client: client, code: code)
        )
        XCTAssertEqual(response.status, 404)
    }
}
