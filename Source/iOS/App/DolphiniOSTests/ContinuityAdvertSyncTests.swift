// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import iCube
import XCTest

/// The continuity advert must name only a port iCube's server holds. iFly and
/// Provenance also want port 80 on the same device, so advertising 80 while
/// iCube's server is down sends peers to another app.
final class ContinuityAdvertSyncTests: XCTestCase {
    private let ip80 = URL(string: "http://192.168.1.20/")!
    private let ipHome = URL(string: "http://192.168.1.20:8091/")!

    // MARK: Bound port

    func testBoundPortComesFromTheServer() {
        XCTAssertEqual(ContinuityAdvertSync.boundPort(serverPort: 8091), 8091)
        XCTAssertEqual(ContinuityAdvertSync.boundPort(serverPort: 8190), 8190)
    }

    func testNoPortWhileTheServerIsDown() {
        // The old code advertised `url?.port ?? 80` here: port 80, which is Provenance's.
        XCTAssertNil(ContinuityAdvertSync.boundPort(serverPort: 0))
    }

    // MARK: Candidates

    func testStaleBonjourURLOnAnotherPortIsDropped() {
        let staleBonjour = URL(string: "http://icube.local/")!
        XCTAssertEqual(
            ContinuityAdvertSync.candidates(serverURL: ipHome, bonjourURL: staleBonjour, boundPort: 8091),
            [ipHome]
        )
        let liveBonjour = URL(string: "http://icube.local:8091/")!
        XCTAssertEqual(
            ContinuityAdvertSync.candidates(serverURL: ipHome, bonjourURL: liveBonjour, boundPort: 8091),
            [ipHome, liveBonjour]
        )
    }

    func testNoCandidatesWithoutABoundPort() {
        XCTAssertEqual(ContinuityAdvertSync.candidates(serverURL: nil, bonjourURL: ip80, boundPort: nil), [])
    }

    // MARK: Decisions

    func testServerMovedPortRepublishes() {
        XCTAssertEqual(ContinuityAdvertSync.action(serverPort: 8080, advertisedPort: 80, candidatesChanged: false), .republish)
        XCTAssertEqual(ContinuityAdvertSync.action(serverPort: 8080, advertisedPort: 80, candidatesChanged: true), .republish)
    }

    func testServerDownWithdraws() {
        XCTAssertEqual(ContinuityAdvertSync.action(serverPort: nil, advertisedPort: 80, candidatesChanged: true), .withdraw)
        XCTAssertEqual(ContinuityAdvertSync.action(serverPort: 0, advertisedPort: 80, candidatesChanged: false), .withdraw)
    }

    func testServerBackAfterWithdrawRepublishes() {
        XCTAssertEqual(ContinuityAdvertSync.action(serverPort: 80, advertisedPort: nil, candidatesChanged: false), .republish)
    }

    func testNothingChangedKeeps() {
        XCTAssertEqual(ContinuityAdvertSync.action(serverPort: 80, advertisedPort: 80, candidatesChanged: false), .keep)
        XCTAssertEqual(ContinuityAdvertSync.action(serverPort: nil, advertisedPort: nil, candidatesChanged: false), .keep)
    }

    func testNewURLsOnTheSamePortRepublish() {
        XCTAssertEqual(ContinuityAdvertSync.action(serverPort: 80, advertisedPort: 80, candidatesChanged: true), .republish)
    }
}
