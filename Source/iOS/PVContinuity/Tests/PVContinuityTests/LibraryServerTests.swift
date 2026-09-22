// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import PVWebServer
import PVContinuityTesting
@testable import PVContinuity

/// Grant enforcement on the library routes, end to end through the registrar.
///
/// Everything here is pure logic — no sockets, no Bonjour, no second device.
/// The behavioural acceptance criteria for WS-4 (two devices on one LAN) are
/// NOT covered by these tests and cannot be; what is covered is every decision
/// the host makes about who may see and copy what.
final class LibraryServerTests: XCTestCase {

    private struct Fixture {
        let server: ContinuityLibraryServer
        let registrar: MockRouteRegistrar
        let provider: MockLibraryProvider
        let trust: FileTrustStore
        let grants: MemoryLibraryGrantStore
        let approver: MockLibraryPullApprover
        let host: ContinuityPeerIdentity
        let peer: ContinuityPeerIdentity
        let gameKey: String
        let gamePath: String
    }

    private let device = SourceDevice(name: "Apple TV", platform: "tvOS", appVersion: "1.0")
    private let gamePath = "Software/melee.rvz"

    private func makeFixture(
        grant: ContinuityLibraryGrant? = nil,
        decision: ContinuityLibraryPullDecision = .allowOnce,
        sharesLibrary: Bool = true,
        pairPeer: Bool = true
    ) async -> Fixture {
        let host = ContinuityPeerIdentity(name: "Apple TV")
        let peer = ContinuityPeerIdentity(name: "iPhone")
        let identity = GameIdentity(
            gameID: "GALE01", displayName: "Melee", platform: "gc", discNumber: 0, revision: 0
        )

        let provider = MockLibraryProvider()
        await provider.setEntries([
            ContinuityLibraryEntry(game: identity, sizeBytes: 1024, hasArtwork: true)
        ])
        await provider.setGameFile(
            FileDescriptor(
                kind: .gameFile,
                relativePath: gamePath,
                sha256: String(repeating: "a", count: 64),
                size: 1024
            ),
            forKey: identity.stableKey
        )
        await provider.setArtwork(Data([0x89, 0x50, 0x4E, 0x47]), forKey: identity.stableKey)

        let trust = FileTrustStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathComponent("trust.json")
        )
        if pairPeer { await trust.add(peer.asTrustedPeer()) }

        let grants = MemoryLibraryGrantStore()
        if let grant { await grants.setGrant(grant, forPeerId: peer.id) }

        let approver = MockLibraryPullApprover(decision: decision)
        let server = ContinuityLibraryServer(
            identity: host,
            libraryProvider: provider,
            trustStore: trust,
            grantStore: grants,
            approver: approver,
            sourceDevice: device,
            sharesLibraryProvider: { sharesLibrary }
        )
        let registrar = MockRouteRegistrar()
        await server.activate(on: registrar)

        return Fixture(
            server: server, registrar: registrar, provider: provider, trust: trust,
            grants: grants, approver: approver, host: host, peer: peer,
            gameKey: identity.stableKey, gamePath: gamePath
        )
    }

    private func encode<T: Encodable>(_ value: T) -> Data { (try? JSONEncoder().encode(value)) ?? Data() }

    private func decode<T: Decodable>(_ type: T.Type, _ response: WebRouteResponse) throws -> T {
        guard case .data(let data) = response.body else {
            throw ContinuityError.invalidResponse(status: response.status)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Runs the library auth exchange and returns the peer-scoped token.
    private func authenticate(_ fixture: Fixture) async throws -> String {
        let start = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.libraryAuthStart,
            body: encode(ContinuityPairingMessages.AuthStartRequest(peerId: fixture.peer.id))
        ))
        XCTAssertEqual(start.status, 200)
        let challenge = try decode(ContinuityPairingMessages.AuthStartResponse.self, start)
        let signature = try ContinuityPairingMath.signAuth(
            nonce: challenge.nonce,
            peerId: fixture.peer.id,
            serverId: challenge.serverId,
            signingKey: fixture.peer.signingKey
        )
        let complete = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.libraryAuthComplete,
            body: encode(ContinuityPairingMessages.AuthCompleteRequest(
                authId: challenge.authId, peerId: fixture.peer.id, signature: signature
            ))
        ))
        XCTAssertEqual(complete.status, 200)
        return try decode(ContinuityLibraryMessages.LibraryTokenResponse.self, complete).libraryToken
    }

    private func authHeaders(_ token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)"]
    }

    // MARK: - Route registration

    func testRegistersEveryLibraryRoute() async throws {
        let fixture = await makeFixture()
        let paths = Set(fixture.registrar.registrations.map(\.path))
        XCTAssertTrue(paths.isSuperset(of: [
            ContinuityRoutes.libraryAuthStart,
            ContinuityRoutes.libraryAuthComplete,
            ContinuityRoutes.libraryCatalog,
            ContinuityRoutes.libraryArtwork,
            ContinuityRoutes.libraryManifest,
            ContinuityRoutes.libraryFile
        ]))
    }

    func testActivateIsIdempotent() async throws {
        let fixture = await makeFixture()
        let before = fixture.registrar.registrations.count
        await fixture.server.activate(on: fixture.registrar)
        XCTAssertEqual(fixture.registrar.registrations.count, before)
    }

    // MARK: - The device-level switch

    /// A host that has not opted in serves nothing — not even an auth challenge.
    func testDeviceThatDoesNotShareServesNothing() async throws {
        let fixture = await makeFixture(sharesLibrary: false)
        let start = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.libraryAuthStart,
            body: encode(ContinuityPairingMessages.AuthStartRequest(peerId: fixture.peer.id))
        ))
        XCTAssertEqual(start.status, 403)

        let catalog = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.libraryCatalog,
            headers: authHeaders("anything")
        ))
        XCTAssertEqual(catalog.status, 403)
    }

    // MARK: - Auth

    func testUnpairedPeerCannotAuthenticate() async throws {
        let fixture = await makeFixture(pairPeer: false)
        let start = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.libraryAuthStart,
            body: encode(ContinuityPairingMessages.AuthStartRequest(peerId: fixture.peer.id))
        ))
        XCTAssertEqual(start.status, 403)
    }

    func testBrowsingWithoutATokenIs401() async throws {
        let fixture = await makeFixture()
        let response = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.libraryCatalog
        ))
        XCTAssertEqual(response.status, 401)
    }

    func testAuthNonceIsSingleUse() async throws {
        let fixture = await makeFixture()
        let start = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.libraryAuthStart,
            body: encode(ContinuityPairingMessages.AuthStartRequest(peerId: fixture.peer.id))
        ))
        let challenge = try decode(ContinuityPairingMessages.AuthStartResponse.self, start)
        let signature = try ContinuityPairingMath.signAuth(
            nonce: challenge.nonce, peerId: fixture.peer.id,
            serverId: challenge.serverId, signingKey: fixture.peer.signingKey
        )
        let body = encode(ContinuityPairingMessages.AuthCompleteRequest(
            authId: challenge.authId, peerId: fixture.peer.id, signature: signature
        ))
        let first = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.libraryAuthComplete, body: body
        ))
        XCTAssertEqual(first.status, 200)
        let replay = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.libraryAuthComplete, body: body
        ))
        XCTAssertEqual(replay.status, 410, "a consumed nonce must not be replayable")
    }

    // MARK: - Browsing is silent for both permissive grants

    func testEverythingBrowsesWithoutPrompting() async throws {
        let fixture = await makeFixture(grant: .everything)
        let token = try await authenticate(fixture)
        let response = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.libraryCatalog, headers: authHeaders(token)
        ))
        XCTAssertEqual(response.status, 200)
        let prompts = await fixture.approver.promptCount
        XCTAssertEqual(prompts, 0)
    }

    /// The point of the `ContinuityLibraryGrant` doc comment: `.askPerGame`
    /// browses **silently**. Re-consenting to every browse would train the
    /// owner to dismiss the prompt that actually matters.
    func testAskPerGameBrowsesSilently() async throws {
        let fixture = await makeFixture(grant: .askPerGame)
        let token = try await authenticate(fixture)

        for path in [ContinuityRoutes.libraryCatalog] {
            let response = try require(await fixture.registrar.send(
                method: "GET", path: path, headers: authHeaders(token)
            ))
            XCTAssertEqual(response.status, 200, "browsing \(path) must not be gated")
        }
        let manifest = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.libraryManifest,
            query: [ContinuityRoutes.libraryKeyQueryKey: fixture.gameKey],
            headers: authHeaders(token)
        ))
        XCTAssertEqual(manifest.status, 200)
        let art = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.libraryArtwork,
            query: [ContinuityRoutes.libraryKeyQueryKey: fixture.gameKey],
            headers: authHeaders(token)
        ))
        XCTAssertEqual(art.status, 200)
        XCTAssertEqual(art.contentType, "image/png")

        let prompts = await fixture.approver.promptCount
        XCTAssertEqual(prompts, 0, "browsing must never prompt — only a pull does")
    }

    /// A peer with no recorded grant is `.askPerGame`, not `.denied`: it can
    /// browse, and the control point is the pull.
    func testPeerWithNoGrantDefaultsToAskPerGame() async throws {
        let fixture = await makeFixture(grant: nil)
        let token = try await authenticate(fixture)
        let response = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.libraryCatalog, headers: authHeaders(token)
        ))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(ContinuityLibraryServer.defaultGrant, .askPerGame)
    }

    // MARK: - Denied

    /// A `.denied` peer is remembered without being trusted: the grant store
    /// holds the "no", the trust store still holds the pairing, and the no wins.
    func testDeniedPeerIsRefusedEvenThoughItIsStillPaired() async throws {
        let fixture = await makeFixture(grant: .denied)
        let stillPaired = await fixture.trust.peer(withId: fixture.peer.id)
        XCTAssertNotNil(stillPaired, "peer is still paired")

        let start = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.libraryAuthStart,
            body: encode(ContinuityPairingMessages.AuthStartRequest(peerId: fixture.peer.id))
        ))
        XCTAssertEqual(start.status, 403)
    }

    /// Denying mid-session invalidates the live token, so an in-flight transfer
    /// stops at its next Range request rather than running to completion.
    func testDenyingMidSessionInvalidatesTheLiveToken() async throws {
        let fixture = await makeFixture(grant: .everything)
        let token = try await authenticate(fixture)
        let before = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.libraryCatalog, headers: authHeaders(token)
        ))
        XCTAssertEqual(before.status, 200)

        await fixture.grants.setGrant(.denied, forPeerId: fixture.peer.id)

        let after = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.libraryCatalog, headers: authHeaders(token)
        ))
        XCTAssertEqual(after.status, 403)
        let liveTokens = await fixture.server.activeTokenCount
        XCTAssertEqual(liveTokens, 0, "the token must be dropped, not just refused")
    }

    /// "Revoking a peer's trust takes effect immediately" — the acceptance
    /// criterion, asserted.
    func testRevokingTrustTakesEffectOnTheVeryNextRequest() async throws {
        let fixture = await makeFixture(grant: .everything)
        let token = try await authenticate(fixture)
        let before = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.libraryCatalog, headers: authHeaders(token)
        ))
        XCTAssertEqual(before.status, 200)

        await fixture.trust.removePeer(withId: fixture.peer.id)

        let after = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.libraryCatalog, headers: authHeaders(token)
        ))
        XCTAssertEqual(after.status, 403)
        let liveTokens = await fixture.server.activeTokenCount
        XCTAssertEqual(liveTokens, 0)
    }

    // MARK: - Pulling

    func testEverythingPullsWithoutPrompting() async throws {
        let fixture = await makeFixture(grant: .everything)
        let token = try await authenticate(fixture)
        let response = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.libraryFile,
            query: [
                ContinuityRoutes.libraryKeyQueryKey: fixture.gameKey,
                ContinuityRoutes.filePathQueryKey: fixture.gamePath
            ],
            headers: authHeaders(token)
        ))
        XCTAssertEqual(response.status, 200)
        let prompts = await fixture.approver.promptCount
        XCTAssertEqual(prompts, 0)
    }

    func testAskPerGamePromptsOnceAndThenRemembersForThatGame() async throws {
        let fixture = await makeFixture(grant: .askPerGame, decision: .allowOnce)
        let token = try await authenticate(fixture)

        // Three requests, as a resumed ranged download would make.
        for _ in 0..<3 {
            let response = try require(await fixture.registrar.send(
                method: "GET", path: ContinuityRoutes.libraryFile,
                query: [
                    ContinuityRoutes.libraryKeyQueryKey: fixture.gameKey,
                    ContinuityRoutes.filePathQueryKey: fixture.gamePath
                ],
                headers: authHeaders(token)
            ))
            XCTAssertEqual(response.status, 200)
        }
        let prompts = await fixture.approver.promptCount
        XCTAssertEqual(prompts, 1, "one logical pull is many HTTP requests; it must prompt once")
        let gameName = await fixture.approver.lastGameName
        let peerName = await fixture.approver.lastPeerName
        XCTAssertEqual(gameName, "Melee")
        XCTAssertEqual(peerName, "iPhone")
    }

    func testAskPerGameDenyOnceRefusesWithoutPersisting() async throws {
        let fixture = await makeFixture(grant: .askPerGame, decision: .denyOnce)
        let token = try await authenticate(fixture)
        let response = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.libraryFile,
            query: [
                ContinuityRoutes.libraryKeyQueryKey: fixture.gameKey,
                ContinuityRoutes.filePathQueryKey: fixture.gamePath
            ],
            headers: authHeaders(token)
        ))
        XCTAssertEqual(response.status, 403)
        let grant = await fixture.grants.grant(forPeerId: fixture.peer.id)
        XCTAssertEqual(grant, .askPerGame, "'not right now' must not harden into a permanent no")
    }

    func testAllowAlwaysPersistsEverything() async throws {
        let fixture = await makeFixture(grant: .askPerGame, decision: .allowAlways)
        let token = try await authenticate(fixture)
        _ = await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.libraryFile,
            query: [
                ContinuityRoutes.libraryKeyQueryKey: fixture.gameKey,
                ContinuityRoutes.filePathQueryKey: fixture.gamePath
            ],
            headers: authHeaders(token)
        )
        let grant = await fixture.grants.grant(forPeerId: fixture.peer.id)
        XCTAssertEqual(grant, .everything)
    }

    /// "Don't Share" is persisted so the owner is not asked again — and is
    /// listed by `allGrants()` so they can undo it. The undo path is why a
    /// persisted no is acceptable at all.
    func testDenyAlwaysPersistsAndIsListedForReview() async throws {
        let fixture = await makeFixture(grant: .askPerGame, decision: .denyAlways)
        let token = try await authenticate(fixture)
        let response = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.libraryFile,
            query: [
                ContinuityRoutes.libraryKeyQueryKey: fixture.gameKey,
                ContinuityRoutes.filePathQueryKey: fixture.gamePath
            ],
            headers: authHeaders(token)
        ))
        XCTAssertEqual(response.status, 403)
        let grant = await fixture.grants.grant(forPeerId: fixture.peer.id)
        XCTAssertEqual(grant, .denied)
        let listed = await fixture.grants.allGrants()[fixture.peer.id]
        XCTAssertEqual(listed, .denied, "a persisted no with no way to list it would be unrecoverable")
    }

    // MARK: - Exclusion, enforced on the wire

    func testExcludedGame404sOnEveryRouteThatNamesIt() async throws {
        let fixture = await makeFixture(grant: .everything)
        let token = try await authenticate(fixture)
        await fixture.provider.setExcluded([fixture.gameKey])

        let manifest = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.libraryManifest,
            query: [ContinuityRoutes.libraryKeyQueryKey: fixture.gameKey],
            headers: authHeaders(token)
        ))
        XCTAssertEqual(manifest.status, 404)

        let art = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.libraryArtwork,
            query: [ContinuityRoutes.libraryKeyQueryKey: fixture.gameKey],
            headers: authHeaders(token)
        ))
        XCTAssertEqual(art.status, 404, "a cover is a strong hint the owner has the game")

        // The one the acceptance criterion turns on: a peer that already knows
        // the relative path still gets nothing.
        let file = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.libraryFile,
            query: [
                ContinuityRoutes.libraryKeyQueryKey: fixture.gameKey,
                ContinuityRoutes.filePathQueryKey: fixture.gamePath
            ],
            headers: authHeaders(token)
        ))
        XCTAssertEqual(file.status, 404)

        let catalog = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.libraryCatalog, headers: authHeaders(token)
        ))
        let decoded = try ContinuityLibraryCatalog.decode(
            from: { if case .data(let d) = catalog.body { return d } else { return Data() } }()
        )
        XCTAssertTrue(decoded.entries.isEmpty)
    }

    /// The manifest is the allow-list, exactly as on the handoff route: a path
    /// it does not describe cannot be fetched, so no crafted `?path=` reaches
    /// outside the disc image.
    func testFileRouteServesOnlyPathsTheManifestDescribes() async throws {
        let fixture = await makeFixture(grant: .everything)
        let token = try await authenticate(fixture)

        for crafted in ["GC/USA/MemoryCardA.raw", "StateSaves/GALE01.s01", "../../../etc/passwd"] {
            let response = try require(await fixture.registrar.send(
                method: "GET", path: ContinuityRoutes.libraryFile,
                query: [
                    ContinuityRoutes.libraryKeyQueryKey: fixture.gameKey,
                    ContinuityRoutes.filePathQueryKey: crafted
                ],
                headers: authHeaders(token)
            ))
            XCTAssertEqual(response.status, 404, "\(crafted) must not be reachable")
        }
    }

    func testFileRouteRequiresBothKeyAndPath() async throws {
        let fixture = await makeFixture(grant: .everything)
        let token = try await authenticate(fixture)

        let noKey = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.libraryFile,
            query: [ContinuityRoutes.filePathQueryKey: fixture.gamePath],
            headers: authHeaders(token)
        ))
        XCTAssertEqual(noKey.status, 400)

        let noPath = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.libraryFile,
            query: [ContinuityRoutes.libraryKeyQueryKey: fixture.gameKey],
            headers: authHeaders(token)
        ))
        XCTAssertEqual(noPath.status, 400)
    }

    // MARK: - Route URL construction

    func testLibraryFileURLCarriesBothKeyAndPath() throws {
        let base = URL(string: "http://host.local:8080")!
        let url = ContinuityRoutes.libraryFileURL(base: base, key: "id:GALE01|d0|r0", relativePath: "Software/a.rvz")
        let items = try require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == ContinuityRoutes.libraryKeyQueryKey }?.value, "id:GALE01|d0|r0")
        XCTAssertEqual(items.first { $0.name == ContinuityRoutes.filePathQueryKey }?.value, "Software/a.rvz")
    }

    func testBearerTokenParsingIsCaseInsensitiveAndRejectsGarbage() {
        XCTAssertEqual(ContinuityLibraryServer.bearerToken(from: "Bearer abc"), "abc")
        XCTAssertEqual(ContinuityLibraryServer.bearerToken(from: "bearer abc"), "abc")
        XCTAssertNil(ContinuityLibraryServer.bearerToken(from: "Bearer "))
        XCTAssertNil(ContinuityLibraryServer.bearerToken(from: "Basic abc"))
        XCTAssertNil(ContinuityLibraryServer.bearerToken(from: nil))
    }
}
