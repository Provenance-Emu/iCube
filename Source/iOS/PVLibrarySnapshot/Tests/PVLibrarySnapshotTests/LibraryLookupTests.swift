import XCTest
@testable import PVLibrarySnapshot

final class LibraryLookupTests: XCTestCase {
    private let melee = LibrarySnapshotGame(id: "GALE01", title: "Super Smash Bros. Melee",
                                            filePath: "/Software/melee.rvz", platform: .gamecube,
                                            gametdbID: "GALE01", region: "USA", lastPlayed: Date(timeIntervalSince1970: 1),
                                            isFavorite: true, coverFilename: "cover_GALE01.jpg")
    private lazy var snapshot = LibrarySnapshot.build(from: [melee])
    private let header = DiscHeader(gameID: "GALE01", makerCode: "01", discNumber: 0, revision: 2,
                                    title: "SUPER SMASH BROS Melee", platform: .gamecube)

    func testRealFilenameStripsICloudPlaceholder() {
        XCTAssertEqual(LibraryLookup.realFilename(from: URL(fileURLWithPath: "/x/.melee.rvz.icloud")), "melee.rvz")
        XCTAssertEqual(LibraryLookup.realFilename(from: URL(fileURLWithPath: "/x/melee.rvz.icloud")), "melee.rvz")
        XCTAssertEqual(LibraryLookup.realFilename(from: URL(fileURLWithPath: "/x/melee.rvz")), "melee.rvz")
        XCTAssertEqual(LibraryLookup.realFilename(from: URL(fileURLWithPath: "/x/.hidden.iso")), ".hidden.iso")
    }

    func testHeaderPlusSnapshotPrefersSnapshotTitle() {
        let r = LibraryLookup.resolve(url: URL(fileURLWithPath: "/x/anything.rvz"), snapshot: snapshot, header: header)
        XCTAssertEqual(r.gameID, "GALE01")
        XCTAssertEqual(r.title, "Super Smash Bros. Melee")
        XCTAssertEqual(r.platform, .gamecube)
        XCTAssertEqual(r.region, "USA")
        XCTAssertTrue(r.isFavorite)
        XCTAssertEqual(r.snapshotGame?.id, "GALE01")
        XCTAssertEqual(r.discNumber, 0)
        XCTAssertEqual(r.makerCode, "01")
    }

    func testHeaderWithoutSnapshotUsesHeaderTitleAndRegionCode() {
        let r = LibraryLookup.resolve(url: URL(fileURLWithPath: "/x/melee.rvz"), snapshot: .empty, header: header)
        XCTAssertEqual(r.title, "SUPER SMASH BROS Melee")
        XCTAssertEqual(r.region, "USA")
        XCTAssertNil(r.snapshotGame)
        XCTAssertFalse(r.isFavorite)
    }

    func testNoHeaderFallsBackToFilenameMatch() {
        let r = LibraryLookup.resolve(url: URL(fileURLWithPath: "/y/melee.rvz"), snapshot: snapshot, header: nil)
        XCTAssertEqual(r.gameID, "GALE01")
        XCTAssertEqual(r.title, "Super Smash Bros. Melee")
    }

    func testNothingKnownDerivesTitleFromFilename() {
        let r = LibraryLookup.resolve(url: URL(fileURLWithPath: "/y/Some_Homebrew-Game.dol"), snapshot: .empty, header: nil)
        XCTAssertNil(r.gameID)
        XCTAssertEqual(r.title, "Some Homebrew Game")
        XCTAssertEqual(r.platform, .unknown)
        XCTAssertNil(r.coverURL)
    }

    func testEmptyHeaderTitleFallsBackToFilename() {
        let blank = DiscHeader(gameID: "GXXE01", makerCode: "01", discNumber: 0, revision: 0, title: "", platform: .gamecube)
        let r = LibraryLookup.resolve(url: URL(fileURLWithPath: "/y/mystery.iso"), snapshot: .empty, header: blank)
        XCTAssertEqual(r.title, "mystery")
    }

    func testRegionNames() {
        XCTAssertEqual(LibraryLookup.regionName(for: "E"), "USA")
        XCTAssertEqual(LibraryLookup.regionName(for: "P"), "Europe")
        XCTAssertEqual(LibraryLookup.regionName(for: "J"), "Japan")
        XCTAssertEqual(LibraryLookup.regionName(for: "K"), "Korea")
        XCTAssertNil(LibraryLookup.regionName(for: nil))
        XCTAssertNil(LibraryLookup.regionName(for: "Z"))
    }
}
