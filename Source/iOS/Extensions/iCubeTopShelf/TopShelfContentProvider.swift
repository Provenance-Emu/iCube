// Source/iOS/Extensions/iCubeTopShelf/TopShelfContentProvider.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
// tvOS Top Shelf rows for iCube. Reads the App Group snapshot written by the app's
// LibrarySnapshotWriter; links nothing but PVLibrarySnapshot + TVServices.
// The target is declared iOS+tvOS for Tuist's sake and embedded on tvOS only, so
// the iOS slice compiles to an empty module.

#if os(tvOS)
import Foundation
import TVServices
import PVLibrarySnapshot
import os

private let log = Logger(subsystem: "com.joemattiello.iCube", category: "topshelf")

final class TopShelfContentProvider: TVTopShelfContentProvider {
    static let maxItemsPerRow = 12

    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        let snapshot = LibrarySnapshotStore().load()
        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []

        func addSection(_ title: String, _ prefix: String, _ games: [LibrarySnapshotGame]) {
            guard !games.isEmpty else { return }
            let items = games.prefix(Self.maxItemsPerRow).map { game -> TVTopShelfSectionedItem in
                let item = TVTopShelfSectionedItem(identifier: "\(prefix)-\(game.id)")
                item.title = game.title
                item.imageShape = .poster
                if let url = game.coverURL, FileManager.default.fileExists(atPath: url.path) {
                    item.setImageURL(url, for: .screenScale1x)
                    item.setImageURL(url, for: .screenScale2x)
                }
                if let launch = game.launchURL {
                    let action = TVTopShelfAction(url: launch)
                    item.displayAction = action
                    item.playAction = action
                }
                return item
            }
            let collection = TVTopShelfItemCollection(items: Array(items))
            collection.title = title
            sections.append(collection)
        }

        addSection("Continue Playing", "recent", snapshot.recentlyPlayed)
        addSection("Favorites", "favorite", snapshot.favorites)
        log.info("load: recent=\(snapshot.recentlyPlayed.count) favorites=\(snapshot.favorites.count) sections=\(sections.count)")

        guard !sections.isEmpty else {
            completionHandler(nil)   // tvOS falls back to the static Top Shelf brand image
            return
        }
        completionHandler(TVTopShelfSectionedContent(sections: sections))
    }
}
#endif
