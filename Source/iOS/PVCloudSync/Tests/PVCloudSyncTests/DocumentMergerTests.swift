// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import PVSyncRules
@testable import PVCloudSync

final class DocumentMergerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Registry

    func testOnlyDocumentCategoriesHaveMergers() {
        for type in SyncableFileType.allCases {
            XCTAssertEqual(DocumentMergers.merger(for: type) != nil, type.mergeKind == .document, "\(type)")
        }
    }

    // MARK: - Library state

    private func state(
        favorite: (Bool, TimeInterval)? = nil,
        lastPlayed: TimeInterval? = nil,
        launches: [String: Int] = [:],
        playSeconds: [String: Int] = [:]
    ) -> LibraryStateDocument.GameState {
        LibraryStateDocument.GameState(
            favorite: favorite.map { .init(value: $0.0, updatedAt: t0.addingTimeInterval($0.1)) },
            lastPlayed: lastPlayed.map { t0.addingTimeInterval($0) },
            launches: launches,
            playSeconds: playSeconds
        )
    }

    func testLibraryStateMergeRules() {
        let a = LibraryStateDocument(games: [
            "GALE01": state(favorite: (true, 10), lastPlayed: 100, launches: ["A": 3], playSeconds: ["A": 600]),
            "ONLYA": state(lastPlayed: 5)
        ])
        let b = LibraryStateDocument(games: [
            "GALE01": state(favorite: (false, 20), lastPlayed: 50, launches: ["A": 2, "B": 7], playSeconds: ["B": 900]),
            "ONLYB": state(favorite: (true, 1))
        ])
        let merged = LibraryStateDocument.merge(a, b)
        let game = merged.games["GALE01"]!
        XCTAssertEqual(game.favorite?.value, false, "newer favorite stamp wins")
        XCTAssertEqual(game.lastPlayed, t0.addingTimeInterval(100), "latest play wins")
        XCTAssertEqual(game.launches, ["A": 3, "B": 7], "per-device max, never a sum")
        XCTAssertEqual(game.totalLaunches, 10)
        XCTAssertEqual(game.playSeconds, ["A": 600, "B": 900])
        XCTAssertEqual(game.totalPlaySeconds, 1500)
        XCTAssertNotNil(merged.games["ONLYA"])
        XCTAssertNotNil(merged.games["ONLYB"])
        XCTAssertEqual(merged.version, LibraryStateDocument.currentVersion)
    }

    func testFavoriteTieBreaksTowardsTrue() {
        let a = state(favorite: (true, 10))
        let b = state(favorite: (false, 10))
        XCTAssertEqual(LibraryStateDocument.GameState.merge(a, b).favorite?.value, true)
        XCTAssertEqual(LibraryStateDocument.GameState.merge(b, a).favorite?.value, true)
    }

    /// The three laws every merger must satisfy, checked on bytes through the
    /// public merger so canonical encoding is covered too.
    func testLibraryStateMergerIsCommutativeAssociativeIdempotent() throws {
        let merger = LibraryStateDocumentMerger()
        let a = try LibraryStateDocument(games: [
            "G1": state(favorite: (true, 1), lastPlayed: 10, launches: ["A": 1], playSeconds: ["A": 10])
        ]).encoded()
        let b = try LibraryStateDocument(games: [
            "G1": state(favorite: (false, 2), lastPlayed: 20, launches: ["B": 4]),
            "G2": state(lastPlayed: 1)
        ]).encoded()
        let c = try LibraryStateDocument(games: [
            "G1": state(launches: ["A": 2], playSeconds: ["C": 5]),
            "G3": state(favorite: (true, 3))
        ]).encoded()

        let ab = try merger.merge(local: a, remote: b)
        let ba = try merger.merge(local: b, remote: a)
        XCTAssertEqual(ab, ba, "commutative")

        let abc1 = try merger.merge(local: ab, remote: c)
        let abc2 = try merger.merge(local: a, remote: merger.merge(local: b, remote: c))
        XCTAssertEqual(abc1, abc2, "associative")

        XCTAssertEqual(try merger.merge(local: abc1, remote: abc1), abc1, "idempotent")
        XCTAssertEqual(try merger.merge(local: abc1, remote: a), abc1, "absorbs an input already merged")
    }

    func testLibraryStateEncodingIsCanonicalAndRoundTrips() throws {
        let doc = LibraryStateDocument(games: ["G": state(favorite: (true, 1), lastPlayed: 2, launches: ["A": 1])])
        let first = try doc.encoded()
        let second = try LibraryStateDocument.decode(first).encoded()
        XCTAssertEqual(first, second)
        XCTAssertEqual(try LibraryStateDocument.decode(first), doc)
        // ISO 8601 dates, sorted keys: readable and stable.
        let text = String(decoding: first, as: UTF8.self)
        XCTAssertTrue(text.contains("\"version\":1"))
        XCTAssertTrue(text.contains("2023-11-14T22:13:21Z"))
    }

    func testEmptyStateDetection() {
        XCTAssertTrue(state().isEmpty)
        XCTAssertFalse(state(lastPlayed: 1).isEmpty)
    }

    // MARK: - Keyed timestamp (game_profiles.json)

    private let profiles = KeyedTimestampDocumentMerger(timestampKey: "updatedAt")

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testKeyedMergeKeepsNewerEntryPerKeyAndUnionsTheRest() throws {
        let local = json([
            "GALE01": ["irMode": 1, "updatedAt": 100],
            "ONLYL": ["irMode": 5]
        ])
        let remote = json([
            "GALE01": ["irMode": 2, "updatedAt": 200],
            "ONLYR": ["irMode": 9, "updatedAt": 1]
        ])
        let merged = try KeyedTimestampDocumentMerger.object(from: profiles.merge(local: local, remote: remote))
        XCTAssertEqual((merged["GALE01"] as? [String: Any])?["irMode"] as? Int, 2)
        XCTAssertEqual((merged["ONLYL"] as? [String: Any])?["irMode"] as? Int, 5)
        XCTAssertEqual((merged["ONLYR"] as? [String: Any])?["irMode"] as? Int, 9)
    }

    /// An entry written before stamping existed counts as oldest.
    func testUnstampedEntryLosesToAnyStampedOne() throws {
        let local = json(["G": ["irMode": 1]])
        let remote = json(["G": ["irMode": 2, "updatedAt": 1]])
        let merged = try KeyedTimestampDocumentMerger.object(from: profiles.merge(local: local, remote: remote))
        XCTAssertEqual((merged["G"] as? [String: Any])?["irMode"] as? Int, 2)
        let reversed = try KeyedTimestampDocumentMerger.object(from: profiles.merge(local: remote, remote: local))
        XCTAssertEqual((reversed["G"] as? [String: Any])?["irMode"] as? Int, 2)
    }

    func testISO8601AndNumericStampsCompare() throws {
        let local = json(["G": ["v": "iso", "updatedAt": "2026-01-02T00:00:00Z"]])
        // 2026-01-01 in seconds since the reference date (what JSONEncoder writes).
        let jan1 = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!.timeIntervalSinceReferenceDate
        let remote = json(["G": ["v": "num", "updatedAt": jan1]])
        let merged = try KeyedTimestampDocumentMerger.object(from: profiles.merge(local: local, remote: remote))
        XCTAssertEqual((merged["G"] as? [String: Any])?["v"] as? String, "iso")
    }

    func testKeyedMergerIsCommutativeAssociativeIdempotent() throws {
        let a = json(["X": ["n": 1, "updatedAt": 1], "Y": ["n": 1, "updatedAt": 5]])
        let b = json(["X": ["n": 2, "updatedAt": 2], "Z": ["n": 3]])
        let c = json(["Y": ["n": 9, "updatedAt": 4], "Z": ["n": 4, "updatedAt": 1]])
        let ab = try profiles.merge(local: a, remote: b)
        XCTAssertEqual(ab, try profiles.merge(local: b, remote: a))
        let abc1 = try profiles.merge(local: ab, remote: c)
        let abc2 = try profiles.merge(local: a, remote: profiles.merge(local: b, remote: c))
        XCTAssertEqual(abc1, abc2)
        XCTAssertEqual(try profiles.merge(local: abc1, remote: abc1), abc1)
    }

    /// Two unstamped, different entries must still merge deterministically.
    func testUnstampedTieIsDeterministic() throws {
        let a = json(["G": ["n": 1]])
        let b = json(["G": ["n": 2]])
        XCTAssertEqual(try profiles.merge(local: a, remote: b), try profiles.merge(local: b, remote: a))
    }

    func testNonObjectInputIsRejected() {
        XCTAssertThrowsError(try profiles.merge(local: Data("[1,2]".utf8), remote: json([:]))) { error in
            XCTAssertEqual(error as? DocumentMergeError, .notAnObject)
        }
    }
}
