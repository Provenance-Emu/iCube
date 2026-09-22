// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import PVWebServer
import PVContinuityTesting
@testable import PVContinuity

// MARK: - Manifest builder allow-list

final class ManifestBuilderTests: XCTestCase {

    private func descriptor(
        _ kind: ContinuityFileKind, _ path: String, size: Int64 = 1024
    ) -> FileDescriptor {
        FileDescriptor(kind: kind, relativePath: path, sha256: "h", size: size)
    }

    func testAPermittedUserDataFilePasses() {
        XCTAssertTrue(ContinuityManifestBuilder.isPermitted(
            descriptor(.gameCubeMemoryCard, "GC/USA/MemoryCardA.raw")
        ))
    }

    func testAPathSyncRulesRejectsIsDropped() {
        // Cache/ is an excluded top-level directory in SyncClassifier.
        XCTAssertFalse(ContinuityManifestBuilder.isPermitted(
            descriptor(.saveStateThumbnail, "Cache/GameCovers/GALE01.png")
        ))
    }

    func testAMislabelledDescriptorIsDropped() {
        // The category cross-check: a provider claiming a disc image is a
        // settings file must not slip past a path-only test.
        XCTAssertFalse(ContinuityManifestBuilder.isPermitted(
            descriptor(.gameSettings, "Software/melee.rvz")
        ))
    }

    func testAFileWhosePathClassifiesAsADifferentCategoryIsDropped() {
        XCTAssertFalse(ContinuityManifestBuilder.isPermitted(
            descriptor(.wiiSave, "GC/USA/MemoryCardA.raw")
        ))
    }

    func testAGameFileIsNeverPermittedThroughTheUserDataPath() {
        // It is added deliberately by the builder, never by classification.
        XCTAssertFalse(ContinuityManifestBuilder.isPermitted(
            descriptor(.gameFile, "Software/melee.rvz")
        ))
    }

    func testAnOversizedFileIsDropped() {
        XCTAssertFalse(ContinuityManifestBuilder.isPermitted(
            descriptor(.gameCubeMemoryCard, "GC/USA/MemoryCardA.raw", size: 1_000_000_000)
        ))
    }

    func testABIOSDumpIsDropped() {
        // ipl.bin is copyrighted console firmware, excluded by name.
        XCTAssertFalse(ContinuityManifestBuilder.isPermitted(
            descriptor(.gameCubeMemoryCard, "GC/ipl.bin")
        ))
    }

    func testTheGlobalConfigIsNotPartOfAHandoffPayload() {
        // Backend, resolution and control layout are device-specific; pushing
        // the sender's onto the receiver would be a hostile surprise.
        XCTAssertFalse(ContinuityManifestBuilder.handoffUserDataKinds.contains(.config))
        XCTAssertTrue(ContinuityManifestBuilder.handoffUserDataKinds.contains(.gameSettings))
    }

    func testBuildFiltersOutAProvidersOverBroadEnumeration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let provider = MockFileProvider(root: root)
        await provider.setEnumeration(
            [descriptor(.gameFile, "Software/melee.rvz")], for: .gameFile
        )
        await provider.setEnumeration(
            [
                descriptor(.gameCubeMemoryCard, "GC/USA/MemoryCardA.raw"),
                // A provider bug: an IPL dump labelled as a memory card.
                descriptor(.gameCubeMemoryCard, "GC/ipl.bin")
            ],
            for: .gameCubeMemoryCard
        )

        let manifest = try await ContinuityManifestBuilder(
            fileProvider: provider,
            sourceDevice: SourceDevice(name: "d", platform: "iOS", appVersion: "1")
        ).build(game: GameIdentity(gameID: "GALE01", displayName: "Melee", platform: "gc"), sessionId: "s")

        let paths = manifest.files.map(\.relativePath)
        XCTAssertTrue(paths.contains("Software/melee.rvz"))
        XCTAssertTrue(paths.contains("GC/USA/MemoryCardA.raw"))
        XCTAssertFalse(paths.contains("GC/ipl.bin"), "the allow-list must catch a provider bug")
    }

    func testTheGameFileCanBeOmittedWhenTheReceiverAlreadyHasIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let provider = MockFileProvider(root: root)
        await provider.setEnumeration([descriptor(.gameFile, "Software/melee.rvz")], for: .gameFile)

        let manifest = try await ContinuityManifestBuilder(
            fileProvider: provider,
            sourceDevice: SourceDevice(name: "d", platform: "iOS", appVersion: "1")
        ).build(
            game: GameIdentity(gameID: "GALE01", displayName: "Melee", platform: "gc"),
            sessionId: "s",
            includeGameFile: false
        )
        XCTAssertTrue(manifest.files.isEmpty)
    }

    func testTheMintedStateIsNotAlsoListedAsAnOrdinaryFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let provider = MockFileProvider(root: root)
        let statePath = "StateSaves/GALE01.s01"
        await provider.setEnumeration(
            [descriptor(.saveStateMetadata, statePath)], for: .saveStateMetadata
        )

        let state = SaveStateDescriptor(
            slot: 1, stem: "GALE01", relativePath: statePath, sha256: "h", size: 1024
        )
        let manifest = try await ContinuityManifestBuilder(
            fileProvider: provider,
            sourceDevice: SourceDevice(name: "d", platform: "iOS", appVersion: "1")
        ).build(
            game: GameIdentity(gameID: "GALE01", displayName: "Melee", platform: "gc"),
            sessionId: "s",
            saveState: state,
            includeGameFile: false
        )
        XCTAssertEqual(manifest.allDescriptors.filter { $0.relativePath == statePath }.count, 1)
    }
}

// MARK: - Session server

final class ContinuitySessionServerTests: XCTestCase {

    private struct Fixture {
        let server: ContinuitySessionServer
        let registrar: MockRouteRegistrar
        let provider: MockFileProvider
        let minter: MockSaveStateMinter
        let root: URL
    }

    private func makeFixture() async -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let provider = MockFileProvider(root: root)
        await provider.setEnumeration(
            [FileDescriptor(kind: .gameFile, relativePath: "Software/melee.rvz", sha256: "h", size: 10)],
            for: .gameFile
        )
        let minter = MockSaveStateMinter(behavior: .succeed(
            SaveStateDescriptor(
                slot: 1, stem: "GALE01", relativePath: "StateSaves/GALE01.s01",
                sha256: "statehash", size: 5
            )
        ))
        let server = ContinuitySessionServer(
            fileProvider: provider,
            minter: minter,
            sourceDevice: SourceDevice(name: "iPhone", platform: "iOS", appVersion: "1.0")
        )
        let registrar = MockRouteRegistrar()
        await server.activate(on: registrar)
        return Fixture(server: server, registrar: registrar, provider: provider, minter: minter, root: root)
    }

    private let game = GameIdentity(gameID: "GALE01", displayName: "Melee", platform: "gc")

    func testActivateRegistersExactlyTheSessionRoutes() async {
        let fixture = await makeFixture()
        let registered = Set(fixture.registrar.registrations.map { "\($0.method) \($0.path)" })
        XCTAssertEqual(registered, [
            "GET \(ContinuityRoutes.manifest)",
            "POST \(ContinuityRoutes.mint)",
            "GET \(ContinuityRoutes.file)"
        ])
    }

    func testActivateIsIdempotent() async {
        let fixture = await makeFixture()
        await fixture.server.activate(on: fixture.registrar)
        XCTAssertEqual(fixture.registrar.registrations.count, 3)
    }

    func testRoutesAnswer404BeforeASessionIsOpen() async {
        let fixture = await makeFixture()
        let response = await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.manifest,
            headers: ["authorization": "Bearer anything"]
        )
        XCTAssertEqual(response?.status, 404)
    }

    func testRoutesAnswer401WithoutTheSessionToken() async {
        let fixture = await makeFixture()
        _ = await fixture.server.beginSession(game: game)
        let response = await fixture.registrar.send(method: "GET", path: ContinuityRoutes.manifest)
        XCTAssertEqual(response?.status, 401)
    }

    func testRoutesAnswer401WithTheWrongToken() async {
        let fixture = await makeFixture()
        _ = await fixture.server.beginSession(game: game)
        let response = await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.manifest,
            headers: ["authorization": "Bearer wrong"]
        )
        XCTAssertEqual(response?.status, 401)
    }

    func testTheManifestIsServedWithTheCorrectToken() async throws {
        let fixture = await makeFixture()
        let session = await fixture.server.beginSession(game: game)
        let response = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.manifest,
            headers: ["authorization": "Bearer \(session.token)"]
        ))
        XCTAssertEqual(response.status, 200)
        guard case .data(let body) = response.body else { return XCTFail("expected a data body") }
        let manifest = try ContinuityManifest.decode(from: body)
        XCTAssertEqual(manifest.sessionId, session.sessionId)
        XCTAssertEqual(manifest.game.gameID, "GALE01")
        XCTAssertNil(manifest.saveState, "nothing has been minted yet")
    }

    func testMintingAddsTheStateToTheManifest() async throws {
        let fixture = await makeFixture()
        let session = await fixture.server.beginSession(game: game)
        let response = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.mint,
            headers: ["authorization": "Bearer \(session.token)"]
        ))
        XCTAssertEqual(response.status, 200)
        guard case .data(let body) = response.body else { return XCTFail("expected a data body") }
        XCTAssertEqual(try ContinuityManifest.decode(from: body).saveState?.stem, "GALE01")
    }

    func testMintingInvalidatesAManifestFetchedBeforeIt() async throws {
        // The regression this guards: fetch manifest (cached, no state) → mint →
        // the state is in the response but NOT in the file route's allow-list.
        let fixture = await makeFixture()
        let session = await fixture.server.beginSession(game: game)
        let auth = ["authorization": "Bearer \(session.token)"]

        _ = await fixture.registrar.send(method: "GET", path: ContinuityRoutes.manifest, headers: auth)
        _ = await fixture.registrar.send(method: "POST", path: ContinuityRoutes.mint, headers: auth)

        let stateURL = fixture.root.appendingPathComponent("StateSaves/GALE01.s01")
        try? FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: stateURL.path, contents: Data(repeating: 7, count: 5))

        let fileResponse = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.file,
            query: [ContinuityRoutes.filePathQueryKey: "StateSaves/GALE01.s01"],
            headers: auth
        ))
        XCTAssertEqual(fileResponse.status, 200, "the minted state must be fetchable")
    }

    func testMintFailureIsReportedRatherThanSwallowed() async throws {
        let fixture = await makeFixture()
        await fixture.minter.setBehavior(.fail(.noActiveSession))
        let session = await fixture.server.beginSession(game: game)
        let response = try require(await fixture.registrar.send(
            method: "POST", path: ContinuityRoutes.mint,
            headers: ["authorization": "Bearer \(session.token)"]
        ))
        XCTAssertEqual(response.status, 500)
    }

    func testTheFileRouteRequiresAPathParameter() async throws {
        let fixture = await makeFixture()
        let session = await fixture.server.beginSession(game: game)
        let response = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.file,
            headers: ["authorization": "Bearer \(session.token)"]
        ))
        XCTAssertEqual(response.status, 400)
    }

    func testOnlyManifestListedPathsAreServable() async throws {
        let fixture = await makeFixture()
        let session = await fixture.server.beginSession(game: game)
        let auth = ["authorization": "Bearer \(session.token)"]

        for hostile in [
            "../../../etc/passwd",
            "/etc/passwd",
            "Software/someone-elses.rvz",
            "StateSaves/RMCE01.s01",
            "Config/Dolphin.ini"
        ] {
            let response = try require(await fixture.registrar.send(
                method: "GET", path: ContinuityRoutes.file,
                query: [ContinuityRoutes.filePathQueryKey: hostile], headers: auth
            ))
            XCTAssertEqual(response.status, 404, "must refuse \(hostile)")
        }
    }

    func testAManifestListedFileIsServedAsAStreamedFileBody() async throws {
        let fixture = await makeFixture()
        let session = await fixture.server.beginSession(game: game)
        let gameURL = fixture.root.appendingPathComponent("Software/melee.rvz")
        try? FileManager.default.createDirectory(
            at: gameURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: gameURL.path, contents: Data(repeating: 1, count: 10))

        let response = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.file,
            query: [ContinuityRoutes.filePathQueryKey: "Software/melee.rvz"],
            headers: ["authorization": "Bearer \(session.token)"]
        ))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["Accept-Ranges"], "bytes")
        guard case .file(_, let offset, let length) = response.body else {
            return XCTFail("a disc image must never be returned as an in-memory body")
        }
        XCTAssertEqual(offset, 0)
        XCTAssertNil(length)
    }

    func testARangeRequestIsAnsweredWith206AndAContentRange() async throws {
        let fixture = await makeFixture()
        let session = await fixture.server.beginSession(game: game)
        let response = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.file,
            query: [ContinuityRoutes.filePathQueryKey: "Software/melee.rvz"],
            headers: ["authorization": "Bearer \(session.token)", "range": "bytes=4-"]
        ))
        XCTAssertEqual(response.status, 206)
        XCTAssertEqual(response.headers["Content-Range"], "bytes 4-9/10")
        guard case .file(_, let offset, let length) = response.body else {
            return XCTFail("expected a file body")
        }
        XCTAssertEqual(offset, 4)
        XCTAssertEqual(length, 6)
    }

    func testAnUnsatisfiableRangeIs416() async throws {
        let fixture = await makeFixture()
        let session = await fixture.server.beginSession(game: game)
        let response = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.file,
            query: [ContinuityRoutes.filePathQueryKey: "Software/melee.rvz"],
            headers: ["authorization": "Bearer \(session.token)", "range": "bytes=99-"]
        ))
        XCTAssertEqual(response.status, 416)
    }

    func testAuthorizationHeaderLookupIsCaseInsensitive() async throws {
        // The server lower-cases header names; a client sends "Authorization".
        let fixture = await makeFixture()
        let session = await fixture.server.beginSession(game: game)
        let response = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.manifest,
            headers: ["Authorization": "Bearer \(session.token)"]
        ))
        XCTAssertEqual(response.status, 200)
    }

    func testBeginningASecondSessionInvalidatesTheFirstToken() async throws {
        let fixture = await makeFixture()
        let first = await fixture.server.beginSession(game: game)
        _ = await fixture.server.beginSession(game: game)
        let response = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.manifest,
            headers: ["authorization": "Bearer \(first.token)"]
        ))
        XCTAssertEqual(response.status, 401)
    }

    func testEndingASessionClosesTheRoutes() async throws {
        let fixture = await makeFixture()
        let session = await fixture.server.beginSession(game: game)
        await fixture.server.endSession()
        let response = try require(await fixture.registrar.send(
            method: "GET", path: ContinuityRoutes.manifest,
            headers: ["authorization": "Bearer \(session.token)"]
        ))
        XCTAssertEqual(response.status, 404)
        let token = await fixture.server.activeToken
        XCTAssertNil(token)
    }
}
