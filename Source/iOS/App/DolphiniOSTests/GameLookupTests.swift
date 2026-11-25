// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import PVLookup
import PVLookupTypes
import PVSQLiteDatabase
import PVSystems
import UIKit
import XCTest

@testable import iCube

private func rom(
  _ title: String = "Super Smash Bros. Melee", system: SystemIdentifier = .GameCube, developer: String? = nil,
  publisher: String? = nil, serial: String? = "GALE01", releaseDate: String? = nil, genres: String? = nil
) -> ROMMetadata {
  ROMMetadata(
    gameTitle: title, developer: developer, publisher: publisher, serial: serial, releaseDate: releaseDate,
    genres: genres, systemID: system, source: "LibretroDB")
}

final class GameLookupQueryTests: XCTestCase {
  func testDiscPlatformsMapToTheSharedSystems() {
    XCTAssertEqual(DiscIOPlatform.gameCubeDisc.systemIdentifier, .GameCube)
    XCTAssertEqual(DiscIOPlatform.triforce.systemIdentifier, .GameCube)
    XCTAssertEqual(DiscIOPlatform.wiiDisc.systemIdentifier, .Wii)
    XCTAssertEqual(DiscIOPlatform.wiiWAD.systemIdentifier, .Wii)
    XCTAssertNil(DiscIOPlatform.elfOrDOL.systemIdentifier)
  }

  func testQueryUsesTheDiscIDAndSystem() {
    let query = GameLookupQuery(gameID: "gale01", platform: DiscIOPlatform.gameCubeDisc.rawValue)
    XCTAssertEqual(query?.serial, "GALE01")
    XCTAssertEqual(query?.system, .GameCube)
    XCTAssertEqual(GameLookupQuery(gameID: "HAAA", platform: DiscIOPlatform.wiiWAD.rawValue)?.system, .Wii)
  }

  func testGamesWithoutADatabaseIDAreNotLookedUp() {
    let disc = DiscIOPlatform.gameCubeDisc.rawValue
    XCTAssertNil(GameLookupQuery(gameID: "<unknown>", platform: disc))
    XCTAssertNil(GameLookupQuery(gameID: "", platform: disc))
    XCTAssertNil(GameLookupQuery(gameID: "GALE0", platform: disc))
    XCTAssertNil(GameLookupQuery(gameID: "GALE01", platform: DiscIOPlatform.elfOrDOL.rawValue))
    XCTAssertNil(GameLookupQuery(gameID: "GALE01", platform: 99))
  }
}

final class GameLookupInfoTests: XCTestCase {
  private let english = Locale(identifier: "en_US")

  func testInfoKeepsWhatTheDatabaseKnows() {
    let info = GameLookupInfo(
      metadata: rom(developer: " HAL Laboratory ", publisher: "Nintendo", releaseDate: "2001-12", genres: "fighting, action"),
      locale: english)
    XCTAssertEqual(info.developer, "HAL Laboratory")
    XCTAssertEqual(info.publisher, "Nintendo")
    XCTAssertEqual(info.released, "December 2001")
    XCTAssertEqual(info.genres, "Fighting, Action")
    XCTAssertFalse(info.isEmpty)
  }

  func testBlankFieldsAreAbsent() {
    let info = GameLookupInfo(metadata: rom(developer: "", publisher: "  ", releaseDate: nil, genres: ""), locale: english)
    XCTAssertTrue(info.isEmpty)
  }

  func testReleaseDateFormats() {
    XCTAssertEqual(GameLookupInfo.releasedText("2003-05", locale: english), "May 2003")
    XCTAssertEqual(GameLookupInfo.releasedText("2001/12/2", locale: english), "December 2001")
    XCTAssertEqual(GameLookupInfo.releasedText("2007", locale: english), "2007")
    XCTAssertEqual(GameLookupInfo.releasedText("2007-13", locale: english), "2007")
    XCTAssertNil(GameLookupInfo.releasedText("soon", locale: english))
    XCTAssertNil(GameLookupInfo.releasedText(nil, locale: english))
  }

  func testLookupAsksByDiscIDAndHidesFailures() async {
    struct Failure: Error {}
    let asked = Asked()
    let lookup = GameLookup(
      search: { query in
        await asked.add(query)
        if query.serial == "FAIL01" { throw Failure() }
        return query.serial == "GALE01" ? rom(developer: "HAL Laboratory") : nil
      },
      artwork: { _ in throw Failure() })
    let disc = DiscIOPlatform.gameCubeDisc.rawValue

    let found = await lookup.info(gameID: "GALE01", platform: disc)
    XCTAssertEqual(found?.developer, "HAL Laboratory")
    let missing = await lookup.info(gameID: "GZLE01", platform: disc)
    XCTAssertNil(missing)
    let failed = await lookup.info(gameID: "FAIL01", platform: disc)
    XCTAssertNil(failed)
    let homebrew = await lookup.info(gameID: "GALE01", platform: DiscIOPlatform.elfOrDOL.rawValue)
    XCTAssertNil(homebrew)
    let urls = await lookup.artworkURLs(for: rom())
    XCTAssertEqual(urls, [])
    let serials = await asked.queries.map(\.serial)
    XCTAssertEqual(serials, ["GALE01", "GZLE01", "FAIL01"])
  }

  private actor Asked {
    var queries: [GameLookupQuery] = []
    func add(_ query: GameLookupQuery) { queries.append(query) }
  }
}

final class LookupCoverPolicyTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func attempt(
    hasCoverArt: Bool = false, usesGameCovers: Bool = true, gametdbID: String = "GALE01", lastAttempt: Date? = nil,
    attemptedThisLaunch: Bool = false
  ) -> Bool {
    LookupCoverPolicy.shouldAttempt(
      hasCoverArt: hasCoverArt, usesGameCovers: usesGameCovers, gametdbID: gametdbID, lastAttempt: lastAttempt,
      attemptedThisLaunch: attemptedThisLaunch, now: now)
  }

  func testOnlyGamesWithoutACoverAreLookedUp() {
    XCTAssertTrue(attempt())
    XCTAssertFalse(attempt(hasCoverArt: true))
  }

  func testTheCoverDownloadSettingTurnsItOff() {
    XCTAssertFalse(attempt(usesGameCovers: false))
  }

  func testAGameIsAskedAboutOncePerLaunchAndAgainAfterAWeek() {
    XCTAssertFalse(attempt(attemptedThisLaunch: true))
    XCTAssertFalse(attempt(lastAttempt: now.addingTimeInterval(-60)))
    XCTAssertTrue(attempt(lastAttempt: now.addingTimeInterval(-LookupCoverPolicy.retryAfter)))
  }

  func testOnlyAPlainIDNamesACachedCover() {
    XCTAssertFalse(attempt(gametdbID: ""))
    XCTAssertFalse(attempt(gametdbID: "<unknown>"))
    XCTAssertFalse(attempt(gametdbID: "../GALE01"))
    XCTAssertTrue(attempt(gametdbID: "HAAA"))
  }

  func testCandidatesAreFrontBoxArtWithLibretroFirst() throws {
    let gameTDB = try XCTUnwrap(URL(string: "https://art.gametdb.com/wii/cover/US/GALE01.png"))
    let theGamesDB = try XCTUnwrap(URL(string: "https://cdn.thegamesdb.net/images/original/boxart/front/5654-1.jpg"))
    let fanArt = try XCTUnwrap(URL(string: "https://cdn.thegamesdb.net/images/original/fanart/5654-3.jpg"))
    let snap = try XCTUnwrap(URL(string: "https://thumbnails.libretro.com/Nintendo%20-%20GameCube/Named_Snaps/Melee.png"))
    let box = try XCTUnwrap(URL(string: "https://thumbnails.libretro.com/Nintendo%20-%20GameCube/Named_Boxarts/Melee.png"))

    XCTAssertEqual(LookupCoverPolicy.candidates(from: [gameTDB, theGamesDB, fanArt, snap, box]), [box, theGamesDB])
    XCTAssertEqual(LookupCoverPolicy.candidates(from: [theGamesDB, box], dead: [box.absoluteString]), [theGamesDB])
    XCTAssertEqual(LookupCoverPolicy.candidates(from: [gameTDB, fanArt, snap]), [])
  }
}

@MainActor
final class LookupCoverFallbackTests: XCTestCase {
  private var directory: URL!
  private var defaults: UserDefaults!
  private var suiteName: String!
  private var refreshed: [String] = []
  private var usesGameCovers = true

  private let box = URL(string: "https://thumbnails.libretro.com/Nintendo%20-%20GameCube/Named_Boxarts/Melee.png")!
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("LookupCoverFallbackTests-\(UUID().uuidString)")
    suiteName = "LookupCoverFallbackTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    refreshed = []
    usesGameCovers = true
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
    defaults.removePersistentDomain(forName: suiteName)
  }

  private func image(width: Int = 1200, height: Int = 1680) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).jpegData(withCompressionQuality: 0.8) {
      UIColor.systemPurple.setFill()
      $0.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
  }

  private func game(_ id: String = "GALE01", hasCoverArt: Bool = false) -> LookupCoverFallback.Game {
    .init(path: "/games/\(id).iso", gameID: id, platform: DiscIOPlatform.gameCubeDisc.rawValue, gametdbID: id, hasCoverArt: hasCoverArt)
  }

  private func fallback(
    urls: [URL], download: @escaping @Sendable (URL) async -> (data: Data, status: Int?)?
  ) -> (LookupCoverFallback, LookupCoverLedger) {
    let ledger = LookupCoverLedger(defaults: defaults)
    let directory = directory!
    let now = now
    let environment = LookupCoverFallback.Environment(
      lookup: GameLookup(search: { $0.serial == "GALE01" ? rom() : nil }, artwork: { _ in urls }),
      usesGameCovers: { [unowned self] in usesGameCovers },
      coverDirectory: { directory },
      download: download,
      refresh: { [unowned self] in refreshed.append($0) },
      now: { now })
    return (LookupCoverFallback(environment: environment, ledger: ledger), ledger)
  }

  func testAMissingCoverIsStoredWhereTheCoreLooksAndTheGameRefreshed() async throws {
    let data = image()
    let (fallback, ledger) = fallback(urls: [box]) { _ in (data, 200) }

    fallback.sweep([game()])
    await fallback.waitUntilIdle()

    let stored = try Data(contentsOf: directory.appendingPathComponent("GALE01.png"))
    let cover = try XCTUnwrap(UIImage(data: stored))
    XCTAssertEqual(Array(stored.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    XCTAssertEqual(max(cover.size.width, cover.size.height), CGFloat(LookupCoverImage.maximumPixelSize))
    XCTAssertEqual(refreshed, ["/games/GALE01.iso"])
    XCTAssertNil(ledger.lastAttempt(for: "GALE01"))
  }

  func testAGameWithACoverOrWithCoversOffIsLeftAlone() async {
    let data = image()
    let (fallback, _) = fallback(urls: [box]) { _ in (data, 200) }

    fallback.sweep([game(hasCoverArt: true)])
    usesGameCovers = false
    fallback.sweep([game()])
    await fallback.waitUntilIdle()

    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("GALE01.png").path))
    XCTAssertEqual(refreshed, [])
  }

  func testNoCoverAnywhereIsRememberedForAWeek() async {
    let (fallback, ledger) = fallback(urls: [box]) { _ in (Data("<html>".utf8), 404) }

    fallback.sweep([game(), game("GZLE01")])
    await fallback.waitUntilIdle()

    XCTAssertEqual(ledger.lastAttempt(for: "GALE01"), now)
    XCTAssertEqual(ledger.lastAttempt(for: "GZLE01"), now, "a game the database does not know is not asked about every launch")
    XCTAssertEqual(refreshed, [])
  }

  func testAFailedRequestIsTriedAgainNextLaunchButNotThisOne() async {
    let requests = Counter()
    let (fallback, ledger) = fallback(urls: [box]) { _ in
      await requests.increment()
      return nil
    }

    fallback.sweep([game()])
    await fallback.waitUntilIdle()
    fallback.sweep([game()])
    await fallback.waitUntilIdle()

    let count = await requests.value
    XCTAssertEqual(count, 1)
    XCTAssertNil(ledger.lastAttempt(for: "GALE01"))
  }

  func testABodyThatIsNotAnImageIsNotStored() {
    XCTAssertNil(LookupCoverImage.png(from: Data("<html>blocked</html>".utf8)))
    XCTAssertNil(LookupCoverImage.png(from: Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0])))
  }

  private actor Counter {
    var value = 0
    func increment() { value += 1 }
  }
}

final class LookupDatabaseSetupTests: XCTestCase {
  func testTheAppBundlesTheDatabasesTheLockFilePins() throws {
    let folder = try XCTUnwrap(Bundle.main.url(forResource: LookupDatabaseSetup.folderName, withExtension: nil))
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("libretrodb.sqlite.zip").path))
    LookupDatabaseSetup.configure()
    XCTAssertTrue(LookupDatabases.isAvailable(.libretrodb))
  }

  /// The real database, as shipped: a GameCube and a Wii disc resolve by the ID on the disc.
  func testShippedDatabaseKnowsGamesByDiscID() async throws {
    LookupDatabaseSetup.configure()
    let melee = await GameLookup.live.metadata(gameID: "GALE01", platform: DiscIOPlatform.gameCubeDisc.rawValue)
    XCTAssertEqual(melee?.gameTitle, "Super Smash Bros. Melee")
    XCTAssertEqual(melee?.systemID, .GameCube)
    XCTAssertEqual(melee?.developer, "HAL Laboratory")
    let galaxy = await GameLookup.live.info(gameID: "RMGE01", platform: DiscIOPlatform.wiiDisc.rawValue)
    XCTAssertEqual(galaxy?.publisher, "Nintendo")
    let unknown = await GameLookup.live.metadata(gameID: "ZZZZ99", platform: DiscIOPlatform.gameCubeDisc.rawValue)
    XCTAssertNil(unknown)
  }
}
