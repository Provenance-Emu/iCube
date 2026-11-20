import XCTest
import PVLibrarySnapshot
@testable import iCube

final class ContinuesListTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func game(_ id: String) -> LibrarySnapshotGame {
        LibrarySnapshotGame(id: id, title: "Game \(id)", filePath: "/Software/\(id).rvz", platform: .gamecube,
                            gametdbID: id, region: nil, lastPlayed: nil, isFavorite: false, coverFilename: nil)
    }

    // MARK: Selection

    func testKeepsTheNewestSaveOfEachGameNewestFirst() {
        let saves = [
            ContinueEntry(gameID: "AAAA01", savedAt: date(10)),
            ContinueEntry(gameID: "BBBB01", savedAt: date(30)),
            ContinueEntry(gameID: "AAAA01", savedAt: date(40)),
            ContinueEntry(gameID: "BBBB01", savedAt: date(20))
        ]
        let selected = ContinuesList.select(saves: saves, knownGameIDs: ["AAAA01", "BBBB01"])
        XCTAssertEqual(selected, [ContinueEntry(gameID: "AAAA01", savedAt: date(40)),
                                  ContinueEntry(gameID: "BBBB01", savedAt: date(30))])
    }

    func testDropsSavesOfGamesNotInTheLibrary() {
        let saves = [ContinueEntry(gameID: "GONE01", savedAt: date(50)), ContinueEntry(gameID: "AAAA01", savedAt: date(10))]
        XCTAssertEqual(ContinuesList.select(saves: saves, knownGameIDs: ["AAAA01"]).map(\.gameID), ["AAAA01"])
    }

    func testStopsAtTheLimit() {
        let saves = (0..<40).map { ContinueEntry(gameID: "G\($0)", savedAt: date(TimeInterval($0))) }
        let selected = ContinuesList.select(saves: saves, knownGameIDs: Set(saves.map(\.gameID)))
        XCTAssertEqual(selected.count, ContinuesList.maxEntries)
        XCTAssertEqual(selected.first?.gameID, "G39")
    }

    func testNoSavesGivesAnEmptyList() {
        XCTAssertTrue(ContinuesList.select(saves: [], knownGameIDs: ["AAAA01"]).isEmpty)
    }

    // MARK: Storage

    func testSaveAndLoadRoundTrip() throws {
        let suite = "ContinuesListTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(ContinuesList.load(from: defaults).isEmpty)
        let entries = [ContinueEntry(gameID: "AAAA01", savedAt: date(40))]
        XCTAssertTrue(ContinuesList.save(entries, to: defaults))
        XCTAssertEqual(ContinuesList.load(from: defaults), entries)
    }

    func testUnavailableAppGroupAndUnreadableDataReadAsEmpty() throws {
        XCTAssertFalse(ContinuesList.save([], to: nil))
        XCTAssertTrue(ContinuesList.load(from: nil).isEmpty)
        let suite = "ContinuesListTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: ContinuesList.defaultsKey)
        XCTAssertTrue(ContinuesList.load(from: defaults).isEmpty)
    }

    // MARK: Widget lookup

    func testGamesFollowTheListOrderAndSkipGamesTheSnapshotLost() {
        let snapshot = LibrarySnapshot.build(from: [game("AAAA01"), game("BBBB01")])
        let entries = [ContinueEntry(gameID: "BBBB01", savedAt: date(30)),
                       ContinueEntry(gameID: "GONE01", savedAt: date(20)),
                       ContinueEntry(gameID: "AAAA01", savedAt: date(10))]
        let games = ContinuesList.games(for: entries, in: snapshot)
        XCTAssertEqual(games.map(\.game.id), ["BBBB01", "AAAA01"])
        XCTAssertEqual(games.map(\.savedAt), [date(30), date(10)])
    }

    // MARK: Scanning the save state folder

    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ContinuesListTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @discardableResult
    private func write(_ name: String, in root: URL, modified: Date) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data([0]).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    func testScanReadsSlotsAutoAndQuickSavesAndSkipsEverythingElse() throws {
        let root = try makeFolder()
        try write("AAAA01.s01", in: root, modified: date(100))
        try write("BBBB01.auto", in: root, modified: date(200))
        try write("CCCC01.quick-\(UUID().uuidString).s01", in: root, modified: date(300))
        // Not save states: a thumbnail, the core's undo file, a folder.
        try write("AAAA01.s01.png", in: root, modified: date(900))
        try write("undo.sav", in: root, modified: date(900))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("DDDD01.s01"), withIntermediateDirectories: true)

        let saves = SaveStateContinuesScanner.scan(root: root)
        XCTAssertEqual(saves, [ContinueEntry(gameID: "CCCC01", savedAt: date(300)),
                               ContinueEntry(gameID: "BBBB01", savedAt: date(200)),
                               ContinueEntry(gameID: "AAAA01", savedAt: date(100))])
    }

    func testScanPrefersTheSidecarsGameAndDate() throws {
        let root = try makeFolder()
        let state = try write("homebrew.s02", in: root, modified: date(100))
        XCTAssertTrue(SaveStateMetadataStore.write(SaveStateMetadata(title: "Boss", gameID: "HOME01", savedAt: date(500)), forStateFile: state))
        XCTAssertEqual(SaveStateContinuesScanner.scan(root: root), [ContinueEntry(gameID: "HOME01", savedAt: date(500))])
    }

    func testScanLooksOnlyAtTheNewestFiles() throws {
        let root = try makeFolder()
        for index in 0..<5 { try write("G\(index)AA01.s01", in: root, modified: date(TimeInterval(index))) }
        XCTAssertEqual(SaveStateContinuesScanner.scan(root: root, limit: 2).map(\.gameID), ["G4AA01", "G3AA01"])
    }

    func testScanOfAMissingFolderIsEmpty() {
        XCTAssertTrue(SaveStateContinuesScanner.scan(root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")).isEmpty)
    }
}
