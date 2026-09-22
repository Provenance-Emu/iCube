// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import PVContinuityTesting
@testable import PVContinuity

final class PullerTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func descriptor(
        _ kind: ContinuityFileKind, _ path: String, contents: Data
    ) -> FileDescriptor {
        FileDescriptor(
            kind: kind, relativePath: path,
            sha256: ContinuityHash.sha256Hex(of: contents),
            size: Int64(contents.count)
        )
    }

    private func manifest(files: [FileDescriptor], saveState: SaveStateDescriptor? = nil) -> ContinuityManifest {
        ContinuityManifest(
            sessionId: "s",
            mintedAt: Date(),
            sourceDevice: SourceDevice(name: "d", platform: "iOS", appVersion: "1"),
            game: GameIdentity(gameID: "GALE01", displayName: "Melee", platform: "gc"),
            saveState: saveState,
            files: files
        )
    }

    private let baseURL = URL(string: "http://peer.local/")!

    // MARK: - Planning

    func testPlanOrdersSmallAndEssentialFilesBeforeTheDiscImage() async {
        let provider = MockFileProvider(root: root)
        let puller = ContinuityPuller(transport: MockTransport(), fileProvider: provider)

        let plan = await puller.makePlan(for: manifest(files: [
            descriptor(.gameFile, "Software/melee.rvz", contents: Data(repeating: 1, count: 4096)),
            descriptor(.wiiSave, "Wii/title/data/banner.bin", contents: Data(repeating: 2, count: 64)),
            descriptor(.gameSettings, "GameSettings/GALE01.ini", contents: Data(repeating: 3, count: 8))
        ], saveState: SaveStateDescriptor(
            slot: 1, stem: "GALE01", relativePath: "StateSaves/GALE01.s01", sha256: "h", size: 256
        )))

        XCTAssertEqual(
            plan.needed.map(\.kind),
            [.gameSettings, .saveState, .wiiSave, .gameFile],
            "a dying transfer must leave saves behind, not half a disc image"
        )
    }

    func testPlanSkipsFilesAlreadyPresentWithMatchingChecksums() async {
        let provider = MockFileProvider(root: root)
        let game = descriptor(.gameFile, "Software/melee.rvz", contents: Data([1, 2, 3]))
        await provider.setStatus(.presentMatching, forRelativePath: game.relativePath)

        let plan = await ContinuityPuller(transport: MockTransport(), fileProvider: provider)
            .makePlan(for: manifest(files: [game]))
        XCTAssertTrue(plan.isNoOp)
        XCTAssertEqual(plan.alreadyPresent.map(\.relativePath), ["Software/melee.rvz"])
    }

    func testAFilePresentButDifferingIsStillPulled() async {
        let provider = MockFileProvider(root: root)
        let save = descriptor(.wiiSave, "Wii/title/data/x.bin", contents: Data([1]))
        await provider.setStatus(.presentDiffering, forRelativePath: save.relativePath)

        let plan = await ContinuityPuller(transport: MockTransport(), fileProvider: provider)
            .makePlan(for: manifest(files: [save]))
        XCTAssertEqual(plan.needed.count, 1)
    }

    func testTotalBytesNeededCountsOnlyWhatWillTransfer() async {
        let provider = MockFileProvider(root: root)
        let present = descriptor(.gameFile, "Software/a.rvz", contents: Data(repeating: 1, count: 100))
        let missing = descriptor(.wiiSave, "Wii/title/data/b.bin", contents: Data(repeating: 2, count: 10))
        await provider.setStatus(.presentMatching, forRelativePath: present.relativePath)

        let plan = await ContinuityPuller(transport: MockTransport(), fileProvider: provider)
            .makePlan(for: manifest(files: [present, missing]))
        XCTAssertEqual(plan.totalBytesNeeded, 10)
    }

    // MARK: - Execution

    func testAFullPullLandsEveryFileAtItsManifestPath() async throws {
        let contents = Data(repeating: 9, count: 1024)
        let game = descriptor(.gameFile, "Software/melee.rvz", contents: contents)
        let transport = MockTransport()
        await transport.stubFile(relativePath: game.relativePath, contents: contents)

        let provider = MockFileProvider(root: root)
        let puller = ContinuityPuller(transport: transport, fileProvider: provider)
        let plan = await puller.makePlan(for: manifest(files: [game]))
        try await puller.execute(plan: plan, baseURL: baseURL, token: "t")

        let landed = root.appendingPathComponent(game.relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: landed.path))
        XCTAssertEqual(try Data(contentsOf: landed), contents)
    }

    func testNoPartialFileIsLeftBehindAfterASuccessfulPull() async throws {
        let contents = Data(repeating: 9, count: 64)
        let game = descriptor(.gameFile, "Software/melee.rvz", contents: contents)
        let transport = MockTransport()
        await transport.stubFile(relativePath: game.relativePath, contents: contents)

        let provider = MockFileProvider(root: root)
        let puller = ContinuityPuller(transport: transport, fileProvider: provider)
        try await puller.execute(
            plan: await puller.makePlan(for: manifest(files: [game])), baseURL: baseURL, token: "t"
        )
        let partial = root.appendingPathComponent(game.relativePath + ".part")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testAChecksumMismatchIsRejectedAndTheFileNeverAppears() async throws {
        // A corrupt save state that LOADS is worse than one that never arrived,
        // because the user has no way to tell.
        let advertised = Data(repeating: 1, count: 64)
        var game = descriptor(.gameFile, "Software/melee.rvz", contents: advertised)
        game.sha256 = String(repeating: "0", count: 64)

        let transport = MockTransport()
        await transport.stubFile(relativePath: game.relativePath, contents: advertised)

        let provider = MockFileProvider(root: root)
        let puller = ContinuityPuller(transport: transport, fileProvider: provider)
        let plan = await puller.makePlan(for: manifest(files: [game]))

        do {
            try await puller.execute(plan: plan, baseURL: baseURL, token: "t")
            XCTFail("a checksum mismatch must not succeed")
        } catch let failure as PullFailure {
            XCTAssertEqual(failure.underlying, .checksumMismatch(relativePath: game.relativePath))
            XCTAssertTrue(failure.completed.isEmpty)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(game.relativePath).path)
        )
    }

    func testAMidTransferFailureReportsWhatCompletedAndWhatDidNot() async throws {
        let stateBytes = Data(repeating: 2, count: 32)
        let gameBytes = Data(repeating: 3, count: 4096)
        let state = descriptor(.saveState, "StateSaves/GALE01.s01", contents: stateBytes)
        let game = descriptor(.gameFile, "Software/melee.rvz", contents: gameBytes)

        let transport = MockTransport()
        await transport.stubFile(relativePath: state.relativePath, contents: stateBytes)
        await transport.stubFile(relativePath: game.relativePath, contents: gameBytes)
        await transport.truncateFile(relativePath: game.relativePath, afterBytes: 1000)

        let provider = MockFileProvider(root: root)
        let puller = ContinuityPuller(transport: transport, fileProvider: provider)
        let plan = await puller.makePlan(for: manifest(files: [state, game]))

        do {
            try await puller.execute(plan: plan, baseURL: baseURL, token: "t")
            XCTFail("expected the truncated game file to fail")
        } catch let failure as PullFailure {
            XCTAssertEqual(failure.completed.map(\.kind), [.saveState])
            XCTAssertEqual(failure.missing.map(\.kind), [.gameFile])

            // …and that translates into the fallback machine's vocabulary.
            let artifacts = failure.pulledArtifacts
            XCTAssertTrue(artifacts.saveStateUsable)
            XCTAssertFalse(artifacts.requiredGameFilesComplete)

            // With the game absent locally too, there is nothing to boot.
            XCTAssertEqual(
                ContinuityFallbackMachine.outcome(
                    failedAt: .pulling, error: failure.underlying,
                    local: .gameMissing, pulled: artifacts
                ),
                .failed(.insufficientToBoot)
            )
            // But with the game already local, the pulled state is enough —
            // reported as `partial` so the UI can name what never arrived.
            XCTAssertEqual(
                ContinuityFallbackMachine.outcome(
                    failedAt: .pulling, error: failure.underlying,
                    local: .gameAvailable(hasLocalSaveState: false), pulled: artifacts
                ),
                .proceedWithPulledStatePartial(missing: [game])
            )
        }
    }

    func testAnInterruptedTransferLeavesAPartialFileForRangeResume() async throws {
        let bytes = Data(repeating: 4, count: 4096)
        let game = descriptor(.gameFile, "Software/melee.rvz", contents: bytes)
        let transport = MockTransport()
        await transport.stubFile(relativePath: game.relativePath, contents: bytes)
        await transport.truncateFile(relativePath: game.relativePath, afterBytes: 1000)

        let provider = MockFileProvider(root: root)
        let puller = ContinuityPuller(transport: transport, fileProvider: provider)
        let plan = await puller.makePlan(for: manifest(files: [game]))
        _ = try? await puller.execute(plan: plan, baseURL: baseURL, token: "t")

        let partial = root.appendingPathComponent(game.relativePath + ".part")
        let size = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        XCTAssertEqual(size, 1000, "the partial must survive so the retry can resume")
    }

    func testARetryResumesFromThePartialAndCompletes() async throws {
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        let game = descriptor(.gameFile, "Software/melee.rvz", contents: bytes)

        let transport = MockTransport()
        await transport.stubFile(relativePath: game.relativePath, contents: bytes)
        await transport.truncateFile(relativePath: game.relativePath, afterBytes: 1000)

        let provider = MockFileProvider(root: root)
        let puller = ContinuityPuller(transport: transport, fileProvider: provider)
        let plan = await puller.makePlan(for: manifest(files: [game]))
        _ = try? await puller.execute(plan: plan, baseURL: baseURL, token: "t")

        // Second attempt: the server is healthy again.
        await transport.healFile(relativePath: game.relativePath)
        try await puller.execute(plan: plan, baseURL: baseURL, token: "t")

        let landed = root.appendingPathComponent(game.relativePath)
        XCTAssertEqual(
            try Data(contentsOf: landed), bytes,
            "a resumed file must be byte-identical, not merely the right length"
        )
    }

    func testProgressIsReportedAcrossTheWholePlanNotPerFile() async throws {
        let a = Data(repeating: 1, count: 100)
        let b = Data(repeating: 2, count: 200)
        let small = descriptor(.gameSettings, "GameSettings/GALE01.ini", contents: a)
        let big = descriptor(.gameFile, "Software/melee.rvz", contents: b)

        let transport = MockTransport()
        await transport.stubFile(relativePath: small.relativePath, contents: a)
        await transport.stubFile(relativePath: big.relativePath, contents: b)

        let provider = MockFileProvider(root: root)
        let puller = ContinuityPuller(transport: transport, fileProvider: provider)
        let plan = await puller.makePlan(for: manifest(files: [small, big]))

        let recorded = Recorder()
        try await puller.execute(plan: plan, baseURL: baseURL, token: "t") { progress in
            recorded.append(progress)
        }

        let snapshots = recorded.snapshots
        XCTAssertFalse(snapshots.isEmpty)
        XCTAssertTrue(snapshots.allSatisfy { $0.totalBytes == 300 })
        XCTAssertEqual(snapshots.last?.bytesTransferred, 300)
        XCTAssertEqual(snapshots.last?.fractionComplete, 1.0)
    }

    func testMintAndFetchManifestUsesThePOSTMintRoute() async throws {
        let transport = MockTransport()
        let body = try manifest(files: []).encoded()
        await transport.stub(path: ContinuityRoutes.mint, responses: [.init(status: 200, body: body)])

        let puller = ContinuityPuller(transport: transport, fileProvider: MockFileProvider(root: root))
        let fetched = try await puller.mintAndFetchManifest(baseURL: baseURL, token: "t")
        XCTAssertEqual(fetched.sessionId, "s")
        let paths = await transport.requestedPaths
        XCTAssertEqual(paths, [ContinuityRoutes.mint])
    }

    func testA401OnTheManifestSurfacesAsTokenRejected() async {
        let transport = MockTransport()
        await transport.stub(path: ContinuityRoutes.manifest, responses: [.init(status: 401)])
        let puller = ContinuityPuller(transport: transport, fileProvider: MockFileProvider(root: root))
        do {
            _ = try await puller.fetchManifest(baseURL: baseURL, token: "t")
            XCTFail("expected a rejection")
        } catch {
            XCTAssertEqual(error as? ContinuityError, .tokenRejected)
        }
    }

    func testA404OnTheManifestSurfacesAsNoActiveSession() async {
        let transport = MockTransport()
        await transport.stub(path: ContinuityRoutes.manifest, responses: [.init(status: 404)])
        let puller = ContinuityPuller(transport: transport, fileProvider: MockFileProvider(root: root))
        do {
            _ = try await puller.fetchManifest(baseURL: baseURL, token: "t")
            XCTFail("expected a rejection")
        } catch {
            XCTAssertEqual(error as? ContinuityError, .noActiveSession)
        }
    }

    func testAnUnsupportedManifestVersionSurfacesLoudly() async throws {
        let transport = MockTransport()
        var future = manifest(files: [])
        future.version = 99
        await transport.stub(
            path: ContinuityRoutes.manifest,
            responses: [.init(status: 200, body: try future.encoded())]
        )
        let puller = ContinuityPuller(transport: transport, fileProvider: MockFileProvider(root: root))
        do {
            _ = try await puller.fetchManifest(baseURL: baseURL, token: "t")
            XCTFail("expected a version rejection")
        } catch {
            XCTAssertEqual(error as? ContinuityError, .manifestVersionUnsupported(found: 99))
        }
    }
}

/// Thread-safe collector for the `@Sendable` progress callback.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PullProgress] = []

    func append(_ progress: PullProgress) {
        lock.lock(); defer { lock.unlock() }
        storage.append(progress)
    }

    var snapshots: [PullProgress] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
