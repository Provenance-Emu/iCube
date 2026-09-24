import XCTest
@testable import PVLibrarySnapshot

final class LibrarySnapshotTests: XCTestCase {
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

    private func game(_ id: String, title: String, lastPlayed: Date? = nil, favorite: Bool = false) -> LibrarySnapshotGame {
        LibrarySnapshotGame(id: id, title: title, filePath: "/Software/\(title).rvz",
                            platform: .gamecube, gametdbID: id, region: "USA",
                            lastPlayed: lastPlayed, isFavorite: favorite, coverFilename: "cover_\(id).jpg")
    }

    func testAppGroupIdentifierIsFixed() {
        XCTAssertEqual(LibrarySnapshotAppGroup.identifier, "group.com.joemattiello.icube")
        XCTAssertEqual(LibrarySnapshotAppGroup.coverFilename(gameID: "GALE01"), "cover_GALE01.jpg")
    }

    func testLaunchURL() {
        let g = game("GALE01", title: "Melee")
        XCTAssertEqual(g.launchURL?.absoluteString, "dolphinios://play?id=GALE01")
    }

    func testBuildSortsRecentsAndFavorites() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let games = [
            game("AAAA01", title: "Zeta", lastPlayed: now.addingTimeInterval(-100), favorite: true),
            game("BBBB01", title: "Alpha", lastPlayed: now, favorite: true),
            game("CCCC01", title: "Mid", lastPlayed: nil, favorite: false),
        ]
        let snap = LibrarySnapshot.build(from: games, now: now)
        XCTAssertEqual(snap.schemaVersion, LibrarySnapshot.currentSchemaVersion)
        XCTAssertEqual(snap.updatedAt, now)
        XCTAssertEqual(snap.recentlyPlayed.map(\.id), ["BBBB01", "AAAA01"], "unplayed games are excluded, newest first")
        XCTAssertEqual(snap.favorites.map(\.title), ["Alpha", "Zeta"], "favorites alphabetical")
        XCTAssertEqual(snap.byGameID.count, 3)
        XCTAssertEqual(snap.game(id: "CCCC01")?.title, "Mid")
        XCTAssertEqual(snap.game(filename: "Mid.rvz")?.id, "CCCC01")
        XCTAssertNil(snap.game(filename: "Nope.iso"))
    }

    func testBuildCapsLists() {
        let games = (0..<40).map { i in
            game(String(format: "G%05d", i), title: "T\(i)", lastPlayed: Date(timeIntervalSince1970: Double(i)), favorite: true)
        }
        let snap = LibrarySnapshot.build(from: games)
        XCTAssertEqual(snap.recentlyPlayed.count, LibrarySnapshot.maxRecentlyPlayed)
        XCTAssertEqual(snap.favorites.count, LibrarySnapshot.maxFavorites)
    }

    func testStoreRoundTrip() {
        let store = LibrarySnapshotStore(defaults: defaults)
        XCTAssertTrue(store.load().byGameID.isEmpty, "empty suite decodes to the empty snapshot")
        let snap = LibrarySnapshot.build(from: [game("GALE01", title: "Melee", lastPlayed: Date())])
        XCTAssertTrue(store.save(snap))
        let loaded = store.load()
        XCTAssertEqual(loaded.recentlyPlayed.first?.id, "GALE01")
        XCTAssertEqual(loaded.byGameID["GALE01"]?.coverFilename, "cover_GALE01.jpg")
    }

    func testStoreRejectsNewerSchema() {
        var snap = LibrarySnapshot.build(from: [game("GALE01", title: "Melee")])
        snap.schemaVersion = LibrarySnapshot.currentSchemaVersion + 1
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        defaults.set(try! enc.encode(snap), forKey: LibrarySnapshotKeys.snapshot)
        XCTAssertTrue(LibrarySnapshotStore(defaults: defaults).load().byGameID.isEmpty)
    }

    func testStoreWithNilDefaultsIsInert() {
        let store = LibrarySnapshotStore(defaults: nil)
        XCTAssertFalse(store.save(.empty))
        XCTAssertTrue(store.load().byGameID.isEmpty)
    }

    func testGarbageDataDecodesToEmpty() {
        defaults.set(Data("not json".utf8), forKey: LibrarySnapshotKeys.snapshot)
        XCTAssertTrue(LibrarySnapshotStore(defaults: defaults).load().byGameID.isEmpty)
    }
}
