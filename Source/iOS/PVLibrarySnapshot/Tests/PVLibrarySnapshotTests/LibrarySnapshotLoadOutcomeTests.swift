import XCTest
@testable import PVLibrarySnapshot

/// `load()` folds every failure into `.empty`; `loadWithOutcome()` says which one happened so the
/// extensions can tell "nothing played yet" apart from "the App Group or the data is broken".
final class LibrarySnapshotLoadOutcomeTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.joemattiello.icube.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func encoded(_ snapshot: LibrarySnapshot) -> Data {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        return try! enc.encode(snapshot)
    }

    func testLoadedSnapshotReportsLoaded() {
        let store = LibrarySnapshotStore(defaults: defaults)
        store.save(LibrarySnapshot(updatedAt: Date(), recentlyPlayed: [], favorites: [], byGameID: [:]))
        let result = store.loadWithOutcome()
        XCTAssertEqual(result.outcome, .loaded)
        XCTAssertFalse(result.outcome.isFailure)
    }

    func testMissingKeyIsNeverWrittenAndNotAFailure() {
        let result = LibrarySnapshotStore(defaults: defaults).loadWithOutcome()
        XCTAssertEqual(result.outcome, .neverWritten)
        XCTAssertFalse(result.outcome.isFailure, "a fresh install has simply not written a snapshot yet")
        XCTAssertTrue(result.snapshot.byGameID.isEmpty)
    }

    func testNilDefaultsIsAppGroupUnavailable() {
        let result = LibrarySnapshotStore(defaults: nil).loadWithOutcome()
        XCTAssertEqual(result.outcome, .appGroupUnavailable)
        XCTAssertTrue(result.outcome.isFailure)
    }

    func testGarbageIsDecodeFailed() {
        defaults.set(Data("not json".utf8), forKey: LibrarySnapshotKeys.snapshot)
        let result = LibrarySnapshotStore(defaults: defaults).loadWithOutcome()
        XCTAssertEqual(result.outcome, .decodeFailed)
        XCTAssertTrue(result.outcome.isFailure)
        XCTAssertTrue(result.snapshot.byGameID.isEmpty)
    }

    func testNewerSchemaCarriesTheVersion() {
        let newer = LibrarySnapshot.currentSchemaVersion + 1
        let snap = LibrarySnapshot(schemaVersion: newer, updatedAt: Date(), recentlyPlayed: [],
                                   favorites: [], byGameID: [:])
        defaults.set(encoded(snap), forKey: LibrarySnapshotKeys.snapshot)
        let result = LibrarySnapshotStore(defaults: defaults).loadWithOutcome()
        XCTAssertEqual(result.outcome, .newerSchema(newer))
        XCTAssertTrue(result.outcome.isFailure)
    }

    func testReasonCodesAreStableAndDistinct() {
        let all: [LibrarySnapshotLoadOutcome] = [.loaded, .neverWritten, .appGroupUnavailable, .decodeFailed, .newerSchema(2)]
        XCTAssertEqual(all.map(\.reason), ["loaded", "never_written", "no_app_group", "decode_failed", "newer_schema"])
    }

    func testLoadMatchesLoadWithOutcome() {
        defaults.set(Data("not json".utf8), forKey: LibrarySnapshotKeys.snapshot)
        let store = LibrarySnapshotStore(defaults: defaults)
        XCTAssertEqual(store.load().byGameID, store.loadWithOutcome().snapshot.byGameID)
    }
}
