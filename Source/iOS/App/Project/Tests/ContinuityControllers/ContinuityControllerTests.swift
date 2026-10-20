import Foundation
import XCTest
import PVContinuity
@testable import Host

private actor PeerTransport: ContinuityTransport {
    let identity = ContinuityPeerIdentity(name: "Provenance")
    var paired: Bool
    var delayManifest = false
    var manifestEntered = false
    var releaseManifest: CheckedContinuation<Void, Never>?
    var delayDownload = false
    var downloadEntered = false
    var releaseDownload: CheckedContinuation<Void, Never>?
    var manifest: ContinuityManifest
    let entry: ContinuityLibraryEntry
    var pairCompleteStatus = 404
    var pairStarts = 0
    var pairCompleteEntered = false
    var requests: [String] = []
    var downloadCalls = 0
    init(paired: Bool = true) {
        self.paired = paired
        let game = GameIdentity(gameID: "GALE01", displayName: "Example", platform: "gc")
        entry = ContinuityLibraryEntry(game: game, sizeBytes: 3, hasArtwork: false)
        manifest = ContinuityManifest(sessionId: "s", mintedAt: Date(),
            sourceDevice: SourceDevice(name: "Provenance", platform: "iOS", appVersion: "1"), game: game,
            files: [FileDescriptor(kind: .gameFile, relativePath: "Software/example.iso",
                sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", size: 3)])
    }
    func replaceManifestHash(_ hash: String) { manifest.files[0].sha256 = hash }
    func setDelayedManifest() { delayManifest = true }
    func setPairCompleteStatus(_ status: Int) { pairCompleteStatus = status }
    func appendUserData() {
        manifest.files.append(FileDescriptor(kind: .gameSettings, relativePath: "GameSettings/GALE01.ini",
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", size: 3))
    }
    func appendSecondROM() {
        var second = manifest.files[0]
        second.relativePath = "Software/example-disc2.iso"
        manifest.files.append(second)
    }
    func unblockManifest() { releaseManifest?.resume(); releaseManifest = nil }
    func setDelayedDownload() { delayDownload = true }
    func unblockDownload() { releaseDownload?.resume(); releaseDownload = nil }
    func request(_ request: ContinuityRequest) async throws -> ContinuityResponse {
        requests.append(request.url.path)
        switch request.url.path {
        case "/api/continuity/library/auth/start", "/api/continuity/auth/start":
            guard paired else { return .init(status: 403) }
            return try json(ContinuityPairingMessages.AuthStartResponse(authId: "a", serverId: identity.id, nonce: Data([1, 2])))
        case "/api/continuity/library/auth/complete":
            return try json(ContinuityLibraryMessages.LibraryTokenResponse(libraryToken: "library"))
        case "/api/continuity/auth/complete":
            return try json(ContinuityPairingMessages.SessionTokenResponse(sessionToken: "handoff"))
        case "/api/continuity/library/catalog":
            return .init(status: 200, body: try ContinuityLibraryCatalog(sourceDevice: manifest.sourceDevice, entries: [entry]).encoded())
        case "/api/continuity/pair/start":
            pairStarts += 1
            return try json(ContinuityPairingMessages.PairStartResponse(pairingId: "pair", serverId: identity.id, serverName: identity.name, serverPublicKey: identity.publicKeyData))
        case "/api/continuity/pair/complete":
            pairCompleteEntered = true
            if pairCompleteStatus == 200 || pairCompleteStatus == 404 { paired = true }
            if pairCompleteStatus == 200 { return try json(ContinuityPairingMessages.SessionTokenResponse(sessionToken: "handoff")) }
            return .init(status: pairCompleteStatus)
        case "/api/continuity/library/manifest", "/api/continuity/mint":
            if delayManifest {
                manifestEntered = true
                // Intentionally ignores cancellation to prove a late response
                // cannot overwrite cancellation or launch emulation.
                await withCheckedContinuation { releaseManifest = $0 }
            }
            return .init(status: 200, body: try manifest.encoded())
        default: return .init(status: 404)
        }
    }
    func json<T: Encodable>(_ value: T) throws -> ContinuityResponse {
        .init(status: 200, body: try JSONEncoder().encode(value))
    }
    func download(_ request: ContinuityRequest, to destination: URL, resumeOffset: Int64,
                  progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> Int64 {
        downloadCalls += 1
        try Data("abc".utf8).write(to: destination)
        progress?(3, 3)
        if delayDownload {
            downloadEntered = true
            await withCheckedContinuation { releaseDownload = $0 }
        }
        return 3
    }
}

@MainActor final class ContinuityControllerTests: XCTestCase {
    override func setUp() async throws {
        UserFolderUtil.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: UserFolderUtil.root.appendingPathComponent("Software"), withIntermediateDirectories: true)
        TVLibraryBridge.registered = []
        TVEmulationBridge.launched = []
        ContinuityManager.shared.recordedHosts = []
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: UserFolderUtil.root) }
    func advertisement(token: String = "") -> ContinuityAdvertisement {
        .init(sessionId: "s", token: token, game: nil, urlCandidates: [URL(string: "http://peer.local")!], sharesLibrary: true)
    }
    func testCancelledPairingApprovalFinishesWithoutUserResponse() async {
        let manager = HostApprovalManager()
        var finished = false
        let approval = Task {
            let allowed = await manager.awaitPairingApproval(peerName: "peer", code: "123456")
            XCTAssertFalse(allowed)
            finished = true
        }
        for _ in 0..<1000 {
            if manager.pendingPairing != nil { break }
            await Task.yield()
        }
        let stalePrompt = manager.pendingPairing
        XCTAssertNotNil(stalePrompt)
        approval.cancel()
        for _ in 0..<1000 {
            if finished { break }
            await Task.yield()
        }
        XCTAssertTrue(finished, "Cancellation must finish without an owner response")
        XCTAssertNil(manager.pendingPairing)
        // Cleanup makes the original failing implementation terminate, and
        // proves that a late answer is harmless after the repaired cancellation.
        stalePrompt?.respond(false)
        await approval.value
    }
    func testCancelledLibraryApprovalFinishesWithoutUserResponse() async {
        let manager = HostApprovalManager()
        var finished = false
        let approval = Task {
            let decision = await manager.awaitLibraryPullApproval(peerName: "peer", gameName: "game")
            XCTAssertEqual(decision, .denyOnce)
            finished = true
        }
        for _ in 0..<1000 {
            if manager.pendingLibraryPull != nil { break }
            await Task.yield()
        }
        let stalePrompt = manager.pendingLibraryPull
        XCTAssertNotNil(stalePrompt)
        approval.cancel()
        for _ in 0..<1000 {
            if finished { break }
            await Task.yield()
        }
        XCTAssertTrue(finished, "Cancellation must finish without an owner response")
        XCTAssertNil(manager.pendingLibraryPull)
        stalePrompt?.respond(.denyOnce)
        await approval.value
    }
    func testLatePairingResponderCannotClearReplacementPrompt() async {
        let manager = HostApprovalManager()
        let first = Task { await manager.awaitPairingApproval(peerName: "first", code: "111111") }
        for _ in 0..<1000 {
            if manager.pendingPairing != nil { break }
            await Task.yield()
        }
        let old = manager.pendingPairing
        first.cancel()
        _ = await first.value
        let second = Task { await manager.awaitPairingApproval(peerName: "second", code: "222222") }
        for _ in 0..<1000 {
            if manager.pendingPairing != nil { break }
            await Task.yield()
        }
        let current = manager.pendingPairing
        XCTAssertNotNil(current)
        old?.respond(true)
        old?.respond(false)
        XCTAssertEqual(manager.pendingPairing?.id, current?.id)
        current?.respond(true)
        let result = await second.value
        XCTAssertTrue(result)
        XCTAssertNil(manager.pendingPairing)
    }
    func testLibraryApprovalHonorsFirstResponseAndIgnoresLateReplacementAnswer() async {
        let manager = HostApprovalManager()
        let first = Task { await manager.awaitLibraryPullApproval(peerName: "first", gameName: "game") }
        for _ in 0..<1000 {
            if manager.pendingLibraryPull != nil { break }
            await Task.yield()
        }
        let old = manager.pendingLibraryPull
        old?.respond(.allowOnce)
        old?.respond(.denyAlways)
        let result = await first.value
        XCTAssertEqual(result, .allowOnce)
        let second = Task { await manager.awaitLibraryPullApproval(peerName: "second", gameName: "game") }
        for _ in 0..<1000 {
            if manager.pendingLibraryPull != nil { break }
            await Task.yield()
        }
        let current = manager.pendingLibraryPull
        old?.respond(.allowAlways)
        XCTAssertEqual(manager.pendingLibraryPull?.id, current?.id)
        current?.respond(.denyOnce)
        _ = await second.value
    }
    func testLibraryOnlyUnknownPeerOffersPairing() async {
        let peer = PeerTransport(paired: false)
        let controller = ContinuityLibraryBrowseController(identity: .init(name: "receiver"), transport: peer)
        await controller.load(from: advertisement())
        XCTAssertEqual(String(describing: controller.phase), "awaitingPairing")
    }
    func testAutomaticBrowseNeverPairsAnUnknownOrRevokedPeer() async {
        let peer = PeerTransport(paired: false)
        let controller = ContinuityLibraryBrowseController(identity: .init(name: "receiver"), transport: peer)
        await controller.load(from: advertisement(), allowsPairing: false)
        let starts = await peer.pairStarts
        XCTAssertEqual(starts, 0)
        guard case .failed = controller.phase else { return XCTFail("Unknown automatic host must fail quietly") }
    }
    func testAutomaticBrowseAllowsExistingTrust() async {
        let peer = PeerTransport()
        let controller = ContinuityLibraryBrowseController(identity: .init(name: "receiver"), transport: peer)
        await controller.load(from: advertisement(), allowsPairing: false)
        XCTAssertEqual(controller.phase, .browsing([peer.entry]))
    }
    func testLibraryPairing404AuthenticatesAndBrowsesWithoutHandoff() async {
        let peer = PeerTransport(paired: false)
        let controller = ContinuityLibraryBrowseController(identity: .init(name: "receiver"), transport: peer)
        await controller.load(from: advertisement())
        await controller.submitPairingCode("123456")
        XCTAssertEqual(controller.phase, .browsing([peer.entry]))
    }
    func testSuccessfulLibraryPairingRemembersApprovedHostExactlyOnce() async {
        let peer = PeerTransport(paired: false)
        let controller = ContinuityLibraryBrowseController(identity: .init(name: "receiver"), transport: peer)
        await controller.load(from: advertisement())
        await controller.submitPairingCode("123456")
        await controller.submitPairingCode("123456")
        let hosts = ContinuityManager.shared.recordedHosts
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts.first?.serverId, peer.identity.id)
        XCTAssertEqual(hosts.first?.serverName, peer.identity.name)
        XCTAssertEqual(hosts.first?.serverPublicKey, peer.identity.publicKeyData)
    }
    func testAdvertisedHostIdentityMismatchCannotProceedToPairing() async {
        let peer = PeerTransport(paired: false)
        let controller = ContinuityLibraryBrowseController(identity: .init(name: "receiver"), transport: peer)
        var offer = advertisement()
        offer.peerId = "another-install"
        await controller.load(from: offer)
        guard case .failed = controller.phase else { return XCTFail("Pairing host must match discovered identity") }
        XCTAssertTrue(ContinuityManager.shared.recordedHosts.isEmpty)
    }
    func testCancelledUnapprovedPairingDoesNotRememberHost() async {
        let peer = PeerTransport(paired: false)
        await peer.setPairCompleteStatus(202)
        let controller = ContinuityLibraryBrowseController(identity: .init(name: "receiver"), transport: peer)
        await controller.load(from: advertisement())
        let pairing = Task { await controller.submitPairingCode("123456") }
        for _ in 0..<1000 {
            if await peer.pairCompleteEntered { break }
            await Task.yield()
        }
        controller.cancel()
        await pairing.value
        XCTAssertTrue(ContinuityManager.shared.recordedHosts.isEmpty)
        XCTAssertEqual(controller.phase, .failed("Cancelled."))
    }
    func testSuccessfulHandoffPairingRemembersHost() async {
        let peer = PeerTransport(paired: false)
        await peer.setPairCompleteStatus(200)
        let controller = ContinuityReceiveController(identity: .init(name: "receiver"), transport: peer)
        await controller.receive(from: advertisement())
        await controller.submitPairingCode("123456")
        XCTAssertEqual(ContinuityManager.shared.recordedHosts.first?.serverId, peer.identity.id)
        XCTAssertEqual(ContinuityManager.shared.recordedHosts.count, 1)
    }
    func testIdleHandoffPairingStillRemembersApprovedHost() async {
        let peer = PeerTransport(paired: false)
        let controller = ContinuityReceiveController(identity: .init(name: "receiver"), transport: peer)
        await controller.receive(from: advertisement())
        await controller.submitPairingCode("123456")
        XCTAssertEqual(ContinuityManager.shared.recordedHosts.first?.serverId, peer.identity.id)
        XCTAssertEqual(controller.phase, .finished(.failed(.noActiveSession)))
    }
    func testWrongPairingCodeCanBeRetried() async {
        let peer = PeerTransport(paired: false)
        await peer.setPairCompleteStatus(401)
        let controller = ContinuityLibraryBrowseController(identity: .init(name: "receiver"), transport: peer)
        await controller.load(from: advertisement())
        await controller.submitPairingCode("000000")
        XCTAssertEqual(String(describing: controller.phase), "awaitingPairing")
        await peer.setPairCompleteStatus(404)
        await controller.submitPairingCode("123456")
        XCTAssertEqual(controller.phase, .browsing([peer.entry]))
    }
    func testMatchingExistingFileIsRegisteredBeforeReportingCopied() async throws {
        let peer = PeerTransport()
        let controller = ContinuityLibraryBrowseController(identity: .init(name: "receiver"), transport: peer)
        let path = ContinuityPaths.absoluteURL(forRelativePath: "Software/example.iso")
        try Data("abc".utf8).write(to: path)
        await controller.load(from: advertisement())
        await controller.copy(peer.entry)
        XCTAssertEqual(TVLibraryBridge.registered, [path.path])
        XCTAssertEqual(controller.copiedFileURL, path)
        XCTAssertEqual(controller.phase, .copied(peer.entry))
    }
    func testCopiedFileURLsIncludeEveryRegisteredROM() async {
        let peer = PeerTransport()
        await peer.appendSecondROM()
        let controller = ContinuityLibraryBrowseController(identity: .init(name: "receiver"), transport: peer)
        await controller.load(from: advertisement())
        await controller.copy(peer.entry)
        XCTAssertEqual(controller.copiedFileURLs.map(\.lastPathComponent), ["example.iso", "example-disc2.iso"])
        XCTAssertEqual(TVLibraryBridge.registered, controller.copiedFileURLs.map(\.path))
    }
    func testOnlyLibraryFileUsesApprovalTransport() async throws {
        let base = PeerTransport()
        let approval = PeerTransport()
        let transport = ICubeContinuityTransport(base: base, approval: approval)
        _ = try await transport.request(.init(url: URL(string: "http://peer.local" + ContinuityRoutes.libraryCatalog)!))
        let path = UserFolderUtil.root.appendingPathComponent("probe.part")
        _ = try await transport.download(.init(url: URL(string: "http://peer.local" + ContinuityRoutes.libraryFile)!),
                                         to: path, resumeOffset: 0, progress: nil)
        _ = try await transport.download(.init(url: URL(string: "http://peer.local" + ContinuityRoutes.file)!),
                                         to: path, resumeOffset: 0, progress: nil)
        let baseRequests = await base.requests
        let approvalRequests = await approval.requests
        let baseDownloads = await base.downloadCalls
        let approvalDownloads = await approval.downloadCalls
        XCTAssertEqual(baseRequests, [ContinuityRoutes.libraryCatalog])
        XCTAssertTrue(approvalRequests.isEmpty)
        XCTAssertEqual(baseDownloads, 1)
        XCTAssertEqual(approvalDownloads, 1)
    }
    func testProviderRejectsTraversalAbsoluteAndSymlinkEscapes() async throws {
        let outside = UserFolderUtil.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: UserFolderUtil.root.appendingPathComponent("escape"), withDestinationURL: outside)
        let provider = ICubeContinuityFileProvider(currentGameFilePath: { nil })
        for path in ["../outside.iso", "/tmp/outside.iso", "escape/outside.iso", "Software/../outside.iso", ""] {
            let descriptor = FileDescriptor(kind: .gameFile, relativePath: path, sha256: "x", size: 1)
            do {
                _ = try await provider.destinationURL(for: descriptor)
                XCTFail("Accepted unsafe path: \(path)")
            } catch {}
        }
    }
    func testProviderAllowsOrdinarySoftwareAndStatePaths() async throws {
        let provider = ICubeContinuityFileProvider(currentGameFilePath: { nil })
        for path in ["Software/Game (USA).rvz", "StateSaves/GALE01.s01", "GC/USA/MemoryCardA.raw"] {
            let descriptor = FileDescriptor(kind: .gameFile, relativePath: path, sha256: "x", size: 1)
            let url = try await provider.destinationURL(for: descriptor)
            XCTAssertEqual(url.standardizedFileURL, UserFolderUtil.root.appendingPathComponent(path).standardizedFileURL)
        }
    }
    func testDifferingROMCollisionPreservesExistingFile() async throws {
        let peer = PeerTransport()
        let controller = ContinuityLibraryBrowseController(identity: .init(name: "receiver"), transport: peer)
        let path = ContinuityPaths.absoluteURL(forRelativePath: "Software/example.iso")
        let original = Data("existing local revision".utf8)
        try original.write(to: path)
        await controller.load(from: advertisement())
        await controller.copy(peer.entry)
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertTrue(TVLibraryBridge.registered.isEmpty)
        XCTAssertNil(controller.copiedFileURL)
        guard case .failed = controller.phase else { return XCTFail("Collision must be visible") }
    }
    func testLibraryCopyRejectsUserDataBeforeWritingAnyFiles() async throws {
        let peer = PeerTransport()
        await peer.appendUserData()
        let controller = ContinuityLibraryBrowseController(identity: .init(name: "receiver"), transport: peer)
        await controller.load(from: advertisement())
        await controller.copy(peer.entry)
        XCTAssertTrue(TVLibraryBridge.registered.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ContinuityPaths.absoluteURL(forRelativePath: "Software/example.iso").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ContinuityPaths.absoluteURL(forRelativePath: "GameSettings/GALE01.ini").path))
        guard case .failed = controller.phase else { return XCTFail("Library copy must reject user data") }
    }
    func testCancelledCopyCannotRegisterWhenManifestReturnsLate() async {
        let peer = PeerTransport()
        let controller = ContinuityLibraryBrowseController(identity: .init(name: "receiver"), transport: peer)
        await controller.load(from: advertisement())
        await peer.setDelayedManifest()
        let copy = Task { await controller.copy(peer.entry) }
        for _ in 0..<10000 {
            if await peer.manifestEntered { break }
            await Task.yield()
        }
        let entered = await peer.manifestEntered
        XCTAssertTrue(entered)
        controller.cancel()
        await peer.unblockManifest()
        await copy.value
        XCTAssertEqual(controller.phase, .failed("Cancelled."))
        XCTAssertTrue(TVLibraryBridge.registered.isEmpty)
    }
    func testCancelledDownloadCannotFinalizeEvenIfDelegateReturnsSuccess() async {
        let peer = PeerTransport()
        await peer.setDelayedDownload()
        let transport = ICubeContinuityTransport(base: peer, approval: peer)
        let controller = ContinuityLibraryBrowseController(identity: .init(name: "receiver"), transport: transport)
        await controller.load(from: advertisement())
        let copy = Task { await controller.copy(peer.entry) }
        for _ in 0..<10000 {
            if await peer.downloadEntered { break }
            await Task.yield()
        }
        let entered = await peer.downloadEntered
        XCTAssertTrue(entered)
        controller.cancel()
        await peer.unblockDownload()
        await copy.value
        let path = ContinuityPaths.absoluteURL(forRelativePath: "Software/example.iso")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathExtension("part").path))
        XCTAssertTrue(TVLibraryBridge.registered.isEmpty)
        XCTAssertEqual(controller.phase, .failed("Cancelled."))
    }
    func testConcurrentCopiesSerializeAndReuseVerifiedDestination() async {
        let first = PeerTransport()
        let second = PeerTransport()
        await first.setDelayedDownload()
        await second.setDelayedDownload()
        let firstController = ContinuityLibraryBrowseController(identity: .init(name: "first"), transport: first)
        let secondController = ContinuityLibraryBrowseController(identity: .init(name: "second"), transport: second)
        await firstController.load(from: advertisement())
        await secondController.load(from: advertisement())
        let firstCopy = Task { await firstController.copy(first.entry) }
        for _ in 0..<10000 {
            if await first.downloadEntered { break }
            await Task.yield()
        }
        let secondCopy = Task { await secondController.copy(second.entry) }
        for _ in 0..<1000 { await Task.yield() }
        let secondEntered = await second.downloadEntered
        XCTAssertFalse(secondEntered, "Another controller must not share the active .part file")
        await first.unblockDownload()
        await second.unblockDownload()
        await firstCopy.value
        await secondCopy.value
        XCTAssertEqual(firstController.phase, .copied(first.entry))
        XCTAssertEqual(secondController.phase, .copied(second.entry))
    }
    func testCancelledQueuedCopyFinishesBeforeActiveTransfer() async {
        let first = PeerTransport()
        let second = PeerTransport()
        await first.setDelayedDownload()
        await second.setDelayedDownload()
        let firstController = ContinuityLibraryBrowseController(identity: .init(name: "first"), transport: first)
        let secondController = ContinuityLibraryBrowseController(identity: .init(name: "second"), transport: second)
        await firstController.load(from: advertisement())
        await secondController.load(from: advertisement())
        let firstCopy = Task { await firstController.copy(first.entry) }
        for _ in 0..<10000 {
            if await first.downloadEntered { break }
            await Task.yield()
        }
        var queuedFinished = false
        let secondCopy = Task {
            await secondController.copy(second.entry)
            queuedFinished = true
        }
        for _ in 0..<1000 { await Task.yield() }
        secondController.cancel()
        for _ in 0..<1000 {
            if queuedFinished { break }
            await Task.yield()
        }
        XCTAssertTrue(queuedFinished, "Queued cancellation must not wait for the active owner")
        await first.unblockDownload()
        await second.unblockDownload()
        await firstCopy.value
        await secondCopy.value
        XCTAssertEqual(secondController.phase, .failed("Cancelled."))
    }
    func testCancelledReceiveCannotLaunchWhenManifestReturnsLate() async {
        let peer = PeerTransport()
        await peer.setDelayedManifest()
        let controller = ContinuityReceiveController(identity: .init(name: "receiver"), transport: peer)
        let receive = Task { await controller.receive(from: advertisement(token: "handoff")) }
        for _ in 0..<10000 {
            if await peer.manifestEntered { break }
            await Task.yield()
        }
        let entered = await peer.manifestEntered
        XCTAssertTrue(entered)
        controller.cancel()
        await peer.unblockManifest()
        await receive.value
        XCTAssertEqual(controller.phase, .finished(.failed(.cancelled)))
        XCTAssertTrue(TVEmulationBridge.launched.isEmpty)
        XCTAssertTrue(TVLibraryBridge.registered.isEmpty)
    }
    func testSelectedPeerMismatchRejectsLibraryAuthBeforeCatalog() async {
        let peer = PeerTransport()
        let controller = ContinuityLibraryBrowseController(identity: .init(name: "receiver"), transport: peer)
        var selected = advertisement()
        selected.peerId = "different-selected-trusted-peer"
        await controller.load(from: selected, allowsPairing: false)
        guard case .failed = controller.phase else { return XCTFail("Selected peer mismatch must fail") }
        let requests = await peer.requests
        XCTAssertFalse(requests.contains(ContinuityRoutes.libraryCatalog))
        XCTAssertFalse(requests.contains(ContinuityRoutes.libraryAuthComplete))
    }
    func testSelectedPeerMismatchRejectsHandoffAuthBeforeManifest() async {
        let peer = PeerTransport()
        let controller = ContinuityReceiveController(identity: .init(name: "receiver"), transport: peer)
        var selected = advertisement()
        selected.peerId = "different-selected-trusted-peer"
        await controller.receive(from: selected)
        let requests = await peer.requests
        XCTAssertFalse(requests.contains(ContinuityRoutes.authComplete))
        XCTAssertFalse(requests.contains(ContinuityRoutes.mint))
        XCTAssertTrue(TVEmulationBridge.launched.isEmpty)
    }

    func testDigestCacheAvoidsRehashingUnchangedFile() throws {
        final class Counter: @unchecked Sendable {
            let lock = NSLock(); var value = 0
            func increment() { lock.lock(); value += 1; lock.unlock() }
        }
        let counter = Counter()
        let file = UserFolderUtil.root.appendingPathComponent("Software/cache.iso")
        try Data("abc".utf8).write(to: file)
        let cache = ContinuityFileDigestCache { url in
            counter.increment()
            return try ContinuityHash.sha256Hex(ofFileAt: url)
        }
        let first = try cache.digest(at: file)
        let second = try cache.digest(at: file)
        XCTAssertEqual(first.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(second.sha256, first.sha256)
        XCTAssertEqual(counter.value, 1, "A 60-second poll must not hash unchanged multi-GB files again")
    }
    func testReceiptCannotSkipSameKeySameSizeChangedRemoteHashAndCollision() async throws {
        let peer = PeerTransport()
        let controller = ContinuityLibraryBrowseController(identity: .init(name: "receiver"), transport: peer)
        await controller.load(from: advertisement())
        await controller.copy(peer.entry)
        let original = await peer.manifest
        let receipt = try ContinuityVerifiedFileReceipt(descriptors: original.files, urls: controller.copiedFileURLs)
        await peer.replaceManifestHash(String(repeating: "a", count: 64))
        let changed = await peer.manifest
        if !receipt.matches(current: changed.files) { await controller.copy(peer.entry) }
        guard case .failed = controller.phase else { return XCTFail("Changed remote checksum must reach collision handling") }
        XCTAssertEqual(try Data(contentsOf: UserFolderUtil.root.appendingPathComponent("Software/example.iso")), Data("abc".utf8))
        let downloadCount = await peer.downloadCalls
        XCTAssertEqual(downloadCount, 1)
    }
    func testReceiptRequiresEveryLocalROMIncludingSecondaryFiles() async throws {
        let peer = PeerTransport(); await peer.appendSecondROM()
        let controller = ContinuityLibraryBrowseController(identity: .init(name: "receiver"), transport: peer)
        await controller.load(from: advertisement()); await controller.copy(peer.entry)
        let manifest = await peer.manifest
        let receipt = try ContinuityVerifiedFileReceipt(descriptors: manifest.files, urls: controller.copiedFileURLs)
        XCTAssertTrue(receipt.matches(current: manifest.files))
        let secondary = controller.copiedFileURLs[1]
        try FileManager.default.removeItem(at: secondary)
        XCTAssertFalse(receipt.matches(current: manifest.files))
        if !receipt.matches(current: manifest.files) { await controller.copy(peer.entry) }
        XCTAssertEqual(controller.phase, .copied(peer.entry))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondary.path))
        let downloadCount = await peer.downloadCalls
        XCTAssertEqual(downloadCount, 3)
    }

    func testMatchingSelectedPeerCanBrowseAndChangedSelectionCannotReuseToken() async {
        let peer = PeerTransport()
        let controller = ContinuityLibraryBrowseController(identity: .init(name: "receiver"), transport: peer)
        var selected = advertisement(); selected.peerId = peer.identity.id
        await controller.load(from: selected, allowsPairing: false)
        guard case .browsing = controller.phase else { return XCTFail("Matching peer must browse") }
        let before = await peer.requests.filter { $0 == ContinuityRoutes.libraryCatalog }.count
        selected.peerId = "other-peer-at-same-endpoint"
        await controller.load(from: selected, allowsPairing: false)
        guard case .failed = controller.phase else { return XCTFail("Cached token must not bypass selection change") }
        let after = await peer.requests.filter { $0 == ContinuityRoutes.libraryCatalog }.count
        XCTAssertEqual(after, before)
    }
    func testDigestCacheDetectsSameSizeWriteEvenWhenMtimeIsPreserved() throws {
        let file = UserFolderUtil.root.appendingPathComponent("Software/cache.iso")
        try Data("abc".utf8).write(to: file)
        let cache = ContinuityFileDigestCache()
        let old = try cache.digest(at: file)
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("xyz".utf8)); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        let fresh = try cache.digest(at: file)
        XCTAssertEqual(fresh.fingerprint.size, old.fingerprint.size)
        XCTAssertNotEqual(fresh.sha256, old.sha256)
        XCTAssertEqual(fresh.sha256, "3608bca1e44ea6c4d268eb6db02260269892c0b42b86bbf1e77a6fa16c3c9282")
    }
    func testDigestChangedDuringHashIsNotPublishedAndStableRetrySucceeds() throws {
        final class Mutation: @unchecked Sendable {
            var first = true
        }
        let mutation = Mutation()
        let file = UserFolderUtil.root.appendingPathComponent("Software/cache.iso")
        try Data("abc".utf8).write(to: file)
        let cache = ContinuityFileDigestCache { url in
            let digest = try ContinuityHash.sha256Hex(ofFileAt: url)
            if mutation.first {
                mutation.first = false
                try Data("xyz".utf8).write(to: url, options: .atomic)
            }
            return digest
        }
        XCTAssertThrowsError(try cache.digest(at: file))
        XCTAssertEqual(try cache.digest(at: file).sha256,
                       "3608bca1e44ea6c4d268eb6db02260269892c0b42b86bbf1e77a6fa16c3c9282")
    }

    func testDigestCacheSupportsConcurrentReadersOfTheSameFile() throws {
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var values: [String] = []
            func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        }
        let results = Results()
        let file = UserFolderUtil.root.appendingPathComponent("Software/cache.iso")
        try Data("abc".utf8).write(to: file)
        let cache = ContinuityFileDigestCache()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do { results.add(try cache.digest(at: file).sha256) }
            catch { results.add("failed: \(error)") }
        }
        XCTAssertEqual(results.values.count, 8)
        XCTAssertEqual(Set(results.values), ["ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"])
    }

}
