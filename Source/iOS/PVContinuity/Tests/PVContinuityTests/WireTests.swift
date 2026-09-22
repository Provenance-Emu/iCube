// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import PVContinuity

// MARK: - Manifest codec

final class ManifestCodecTests: XCTestCase {

    private func sampleManifest(version: Int = ContinuityManifest.currentVersion) -> ContinuityManifest {
        ContinuityManifest(
            version: version,
            sessionId: "session-1",
            mintedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceDevice: SourceDevice(name: "iPhone", platform: "iOS", appVersion: "1.0"),
            game: GameIdentity(gameID: "GALE01", md5: "abc", displayName: "Melee", platform: "gc"),
            saveState: SaveStateDescriptor(
                slot: 1, stem: "GALE01", relativePath: "StateSaves/GALE01.s01",
                sha256: "deadbeef", size: 2048
            ),
            files: [
                FileDescriptor(kind: .gameFile, relativePath: "Software/melee.rvz", sha256: "aaa", size: 1_000_000),
                FileDescriptor(kind: .gameCubeMemoryCard, relativePath: "GC/USA/MemoryCardA.raw", sha256: "bbb", size: 512)
            ]
        )
    }

    func testRoundTrip() throws {
        let original = sampleManifest()
        let decoded = try ContinuityManifest.decode(from: try original.encoded())
        XCTAssertEqual(decoded, original)
    }

    func testEncodingIsStableAcrossCalls() throws {
        // Sorted keys + ISO 8601 dates, so two devices produce identical bytes
        // for identical content.
        let manifest = sampleManifest()
        XCTAssertEqual(try manifest.encoded(), try manifest.encoded())
    }

    func testAnUnsupportedVersionIsRejectedAtDecodeTime() throws {
        // Loud failure beats parsing a subset and pulling half a payload.
        let data = try sampleManifest(version: 99).encoded()
        XCTAssertThrowsError(try ContinuityManifest.decode(from: data)) { error in
            XCTAssertEqual(error as? ContinuityError, .manifestVersionUnsupported(found: 99))
        }
    }

    func testGarbageDoesNotDecode() {
        XCTAssertThrowsError(try ContinuityManifest.decode(from: Data("{}".utf8)))
    }

    func testAllDescriptorsIncludesTheSaveState() {
        let manifest = sampleManifest()
        XCTAssertEqual(manifest.allDescriptors.count, 3)
        XCTAssertTrue(manifest.allDescriptors.contains { $0.kind == .saveState })
    }

    func testAllDescriptorsOmitsTheSaveStateWhenNoneWasMinted() {
        var manifest = sampleManifest()
        manifest.saveState = nil
        XCTAssertEqual(manifest.allDescriptors.count, 2)
    }

    func testDescriptorLookupIsAnExactPathMatch() {
        let manifest = sampleManifest()
        XCTAssertNotNil(manifest.descriptor(forRelativePath: "Software/melee.rvz"))
        XCTAssertNil(manifest.descriptor(forRelativePath: "Software/melee"))
        XCTAssertNil(manifest.descriptor(forRelativePath: "software/melee.rvz"))
        XCTAssertNil(manifest.descriptor(forRelativePath: "../Software/melee.rvz"))
    }
}

// MARK: - Advertisement + TXT record

final class AdvertisementCodecTests: XCTestCase {

    private func sampleAdvertisement(token: String = "secret-token") -> ContinuityAdvertisement {
        ContinuityAdvertisement(
            sessionId: "session-1",
            token: token,
            game: GameIdentity(
                gameID: "GALE01", md5: "abc", crc32: "d00d", displayName: "Melee",
                platform: "gc", discNumber: 0, revision: 2
            ),
            saveStateStem: "GALE01",
            urlCandidates: [URL(string: "http://icube.local/")!, URL(string: "http://192.168.1.5/")!],
            sharesLibrary: true,
            peerId: "peer-1",
            deviceType: "ip"
        )
    }

    func testTXTRoundTrip() throws {
        let original = sampleAdvertisement()
        let decoded = try XCTUnwrap(ContinuityTXTRecord.decode(ContinuityTXTRecord.encode(original)))
        XCTAssertEqual(decoded.sessionId, original.sessionId)
        XCTAssertEqual(decoded.game?.gameID, "GALE01")
        XCTAssertEqual(decoded.game?.discNumber, 0)
        XCTAssertEqual(decoded.game?.revision, 2)
        XCTAssertEqual(decoded.urlCandidates, original.urlCandidates)
        XCTAssertTrue(decoded.sharesLibrary)
        XCTAssertEqual(decoded.peerId, "peer-1")
        XCTAssertEqual(decoded.deviceType, "ip")
        XCTAssertEqual(decoded.saveStateStem, "GALE01")
    }

    func testRedactionRemovesTheToken() {
        XCTAssertEqual(sampleAdvertisement().redactedForBonjour().token, "")
    }

    func testARedactedAdvertisementPublishesNoTokenKeyAtAll() {
        // Not a blank value — a blank value invites somebody to treat the empty
        // string as a token.
        let txt = ContinuityTXTRecord.encode(sampleAdvertisement().redactedForBonjour())
        XCTAssertNil(txt["tok"])
        XCTAssertFalse(txt.values.contains("secret-token"))
    }

    func testNoTXTValueLeaksTheTokenAnywhere() {
        let txt = ContinuityTXTRecord.encode(sampleAdvertisement().redactedForBonjour())
        for (key, value) in txt {
            XCTAssertFalse(value.contains("secret-token"), "token leaked through key \(key)")
        }
    }

    func testADecodedRedactedAdvertisementRequiresPairing() throws {
        let txt = ContinuityTXTRecord.encode(sampleAdvertisement().redactedForBonjour())
        let decoded = try XCTUnwrap(ContinuityTXTRecord.decode(txt))
        XCTAssertTrue(decoded.requiresPairing)
        XCTAssertEqual(decoded.token, "")
    }

    func testAnUnredactedAdvertisementDoesCarryItsToken() {
        // The Handoff path is same-user and private, so it may.
        let txt = ContinuityTXTRecord.encode(sampleAdvertisement())
        XCTAssertEqual(txt["tok"], "secret-token")
    }

    func testAPresenceAdvertWithNoGameRoundTrips() throws {
        let presence = ContinuityAdvertisement(
            sessionId: "p", token: "", game: nil, urlCandidates: [], sharesLibrary: true, peerId: "peer"
        )
        let decoded = try XCTUnwrap(ContinuityTXTRecord.decode(ContinuityTXTRecord.encode(presence)))
        XCTAssertNil(decoded.game)
        XCTAssertTrue(decoded.sharesLibrary)
    }

    func testAMalformedTXTDecodesToNilRatherThanAHalfBuiltPeer() {
        XCTAssertNil(ContinuityTXTRecord.decode([:]))
        XCTAssertNil(ContinuityTXTRecord.decode(["v": "notanumber", "sid": "x"]))
        XCTAssertNil(ContinuityTXTRecord.decode(["v": "1"]))
    }

    func testLongDisplayNamesAreTruncatedToFitATXTString() {
        var advertisement = sampleAdvertisement()
        advertisement.game?.displayName = String(repeating: "A", count: 400)
        let txt = ContinuityTXTRecord.encode(advertisement)
        XCTAssertEqual(txt["name"]?.count, 180)
    }

    func testAnAdvertisementWithNoURLsDecodesWithNoURLs() {
        // The case that actually bites: the web server's NWListener binds
        // asynchronously, so publishing too early ships a TXT record with no
        // `u0` and the receiver fails at its first step with "advertised no
        // address". The codec must round-trip that honestly rather than
        // inventing a candidate — the sender is responsible for not publishing
        // it (see ContinuityManager.awaitServerURLCandidates).
        var advertisement = sampleAdvertisement()
        advertisement.urlCandidates = []
        let txt = ContinuityTXTRecord.encode(advertisement)
        XCTAssertNil(txt["u0"])

        let decoded = ContinuityTXTRecord.decode(txt)
        XCTAssertNotNil(decoded, "a session with no address is still a decodable advertisement")
        XCTAssertTrue(decoded?.urlCandidates.isEmpty == true)
    }

    func testURLCandidatesStopAtTheFirstGap() {
        // Decoding walks u0, u1, … and stops at the first missing index, so a
        // record that somehow lost u0 yields none rather than silently
        // promoting u1 to primary.
        var txt = ContinuityTXTRecord.encode(sampleAdvertisement())
        txt["u0"] = nil
        XCTAssertTrue(ContinuityTXTRecord.decode(txt)?.urlCandidates.isEmpty == true)
    }

    func testOnlyTheFirstFourURLCandidatesArePublished() {
        var advertisement = sampleAdvertisement()
        advertisement.urlCandidates = (0..<8).map { URL(string: "http://host\($0)/")! }
        let txt = ContinuityTXTRecord.encode(advertisement)
        XCTAssertNotNil(txt["u3"])
        XCTAssertNil(txt["u4"])
    }

    func testUserActivityRoundTrip() throws {
        let original = sampleAdvertisement()
        let decoded = try XCTUnwrap(ContinuityAdvertisement(userInfo: original.userInfoRepresentation))
        XCTAssertEqual(decoded, original)
    }

    func testUserActivityDecodeRejectsForeignPayloads() {
        XCTAssertNil(ContinuityAdvertisement(userInfo: nil))
        XCTAssertNil(ContinuityAdvertisement(userInfo: ["somethingElse": 1]))
    }

    func testActivityTypeIsTheICubeOne() {
        // Must match the NSUserActivityTypes entry in Info.plist / Info-TV.plist.
        XCTAssertEqual(ContinuityAdvertisement.activityType, "com.joemattiello.icube.continuity.play")
    }

    func testServiceTypeIsTheICubeOne() {
        // Must match the NSBonjourServices entry in both Info.plists.
        XCTAssertEqual(ContinuityService.type, "_icube-continuity._tcp")
    }
}

// MARK: - Byte ranges

final class ByteRangeRequestTests: XCTestCase {

    func testOpenEndedRange() {
        let range = ByteRangeRequest.parse(header: "bytes=100-")
        XCTAssertEqual(range, ByteRangeRequest(offset: 100))
        XCTAssertEqual(range?.length(totalSize: 500), 400)
        XCTAssertEqual(range?.contentRange(totalSize: 500), "bytes 100-499/500")
    }

    func testClosedRange() {
        let range = ByteRangeRequest.parse(header: "bytes=10-19")
        XCTAssertEqual(range, ByteRangeRequest(offset: 10, end: 19))
        XCTAssertEqual(range?.length(totalSize: 500), 10)
        XCTAssertEqual(range?.contentRange(totalSize: 500), "bytes 10-19/500")
    }

    func testARangeEndPastTheFileIsClampedNotRejected() {
        let range = ByteRangeRequest.parse(header: "bytes=0-9999")
        XCTAssertEqual(range?.length(totalSize: 100), 100)
        XCTAssertEqual(range?.contentRange(totalSize: 100), "bytes 0-99/100")
    }

    func testARangeStartingPastTheFileIsUnsatisfiable() {
        let range = ByteRangeRequest.parse(header: "bytes=500-")
        XCTAssertNil(range?.length(totalSize: 100))
        XCTAssertNil(range?.contentRange(totalSize: 100))
    }

    func testResumingAtExactlyTheFileLengthIsUnsatisfiable() {
        // The resume path must not ask for a zero-length tail and call it success.
        let range = ByteRangeRequest.parse(header: "bytes=100-")
        XCTAssertNil(range?.length(totalSize: 100))
    }

    func testMalformedHeadersParseAsNilSoTheWholeFileIsServed() {
        for header in ["", "items=0-1", "bytes=", "bytes=abc-", "bytes=-50", "bytes=20-10", "bytes=-5-"] {
            XCTAssertNil(ByteRangeRequest.parse(header: header), "for \(header)")
        }
        XCTAssertNil(ByteRangeRequest.parse(header: nil))
    }

    func testMultiRangeIsDeliberatelyUnsupported() {
        XCTAssertNil(ByteRangeRequest.parse(header: "bytes=0-1,5-6"))
    }

    func testNegativeOffsetsAreRejected() {
        XCTAssertNil(ByteRangeRequest.parse(header: "bytes=-1-5"))
    }
}
