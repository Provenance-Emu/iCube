import Foundation
import PVLibrarySnapshot
import PVHelp
import XCTest
@testable import iCube

final class SharedPackageMigrationTests: XCTestCase {
    func testOldSnapshotGameStillDecodesAndLaunches() throws {
        // JSON written before LibrarySnapshotGame.platform became a String.
        let oldJSON = Data(#"{"id":"GALE01","title":"Melee","filePath":"/Software/melee.iso","platform":"gamecube","isFavorite":true}"#.utf8)
        let game = try JSONDecoder().decode(LibrarySnapshotGame.self, from: oldJSON)
        XCTAssertEqual(game.icubePlatform, .gamecube)
        XCTAssertEqual(game.launchURL?.absoluteString, "dolphinios://play?id=GALE01")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(game)) as! [String: Any]
        XCTAssertEqual(encoded["platform"] as? String, "gamecube")
    }

    func testBundledWikiSurvivesAnUnavailableRemote() async throws {
        var configuration = ICubeWiki.configuration
        // A fresh cache and unsupported URL scheme force the bundled fallback.
        configuration.cacheNamespace = "iCubeWikiMigration-\(UUID().uuidString)"
        configuration.baseURL = URL(fileURLWithPath: "/nonexistent-icube-wiki")
        let provider = WikiContentProvider(configuration: configuration)
        let page = await provider.loadPage(path: ICubeWiki.Paths.biosRequirements, title: "BIOS")
        XCTAssertGreaterThan(page.content.count, 100)
        XCTAssertFalse(page.content.contains("This page is not yet cached"))
    }
}
