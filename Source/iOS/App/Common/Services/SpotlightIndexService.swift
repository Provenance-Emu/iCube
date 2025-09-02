import Foundation
import UIKit
import CoreSpotlight
import UniformTypeIdentifiers

class SpotlightIndexService: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        indexAllGames()
        NotificationCenter.default.addObserver(self, selector: #selector(reindexOnLibraryUpdate), name: NSNotification.Name("RemoteLibraryUpdated"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reindexOnMetadataUpdate(_:)), name: NSNotification.Name("GameFileMetadataUpdated"), object: nil)
        return true
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
      #if !os(tvOS)
        guard userActivity.activityType == CSSearchableItemActionType,
              let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              identifier.hasPrefix("dios.game.") else { return false }
        let gameID = String(identifier.dropFirst("dios.game.".count))
        NotificationCenter.default.post(name: NSNotification.Name("DOLLaunchGameByGameID"), object: nil, userInfo: ["gameID": gameID])
      #endif
        return true
    }

    @objc private func reindexOnLibraryUpdate() {
        indexAllGames()
    }

    @objc private func reindexOnMetadataUpdate(_ note: Notification) {
        // Reindex just the one if we have its filePath; otherwise fall back to all
        if let filePath = note.userInfo?["filePath"] as? String {
            indexGames(matching: { $0.filePath == filePath })
        } else {
            indexAllGames()
        }
    }

    private func indexAllGames() {
        let games = TVLibraryBridge.currentGames()
        index(items: games)
    }

    private func indexGames(matching predicate: (TVGameItem) -> Bool) {
        let games = TVLibraryBridge.currentGames().filter(predicate)
        index(items: games)
    }

    private func index(items: [TVGameItem]) {
#if !os(tvOS)
        var searchable: [CSSearchableItem] = []
        for game in items {
            let attr = CSSearchableItemAttributeSet(contentType: UTType.item)
            attr.title = game.title
            var lines: [String] = []
            if !game.makerLong.isEmpty { lines.append(game.makerLong) }
            if let date = game.apploaderDateString, let year = date.split(separator: "/").first { lines.append(String(year)) }
            if !game.countryName.isEmpty { lines.append(game.countryName) }
            if !game.gametdbID.isEmpty { lines.append(game.gametdbID) }
            attr.contentDescription = lines.isEmpty ? game.gameID : (lines.joined(separator: " • "))
            attr.thumbnailData = game.coverImage.pngData()
            let uniqueId = "dios.game.\(game.gameID)"
            let item = CSSearchableItem(uniqueIdentifier: uniqueId, domainIdentifier: "dios.games", attributeSet: attr)
            searchable.append(item)
        }
        CSSearchableIndex.default().indexSearchableItems(searchable, completionHandler: nil)
      #endif
    }
}
