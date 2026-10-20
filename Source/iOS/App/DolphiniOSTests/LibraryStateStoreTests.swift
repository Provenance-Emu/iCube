// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import PVCloudSync
import XCTest
@testable import iCube

final class LibraryStateStoreTests: XCTestCase {
  private func fixture() throws -> (URL, UserDefaults) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryState-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "LibraryStateTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    return (root.appendingPathComponent("library_state.json"), defaults)
  }

  func testStartupPreservesPersistedFavoriteOverStaleDefaultsMirror() throws {
    let (file, defaults) = try fixture()
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    let document = LibraryStateDocument(games: ["TEST01": .init(favorite: .init(value: false, updatedAt: stamp))])
    try document.encoded().write(to: file)
    defaults.set(["TEST01": true, "LEGACY": true], forKey: "favorites_by_gameid")
    let store = LibraryStateStore(fileURL: file, defaults: defaults, deviceID: "test")
    XCTAssertFalse(store.isFavorite("TEST01"))
    XCTAssertEqual(store.state(for: "TEST01")?.favorite?.updatedAt, stamp)
    XCTAssertTrue(store.isFavorite("LEGACY"), "Missing document entries still migrate")
    XCTAssertEqual((defaults.dictionary(forKey: "favorites_by_gameid") as? [String: Bool])?["TEST01"], false)
  }

  func testReloadMergesInMemoryCountersWithDownloadedDocumentAndPersistsUnion() throws {
    let (file, defaults) = try fixture()
    let store = LibraryStateStore(fileURL: file, defaults: defaults, deviceID: "local")
    store.recordLaunch(gameID: "LOCAL")
    let remote = LibraryStateDocument(games: ["REMOTE": .init(launches: ["other": 2])])
    try remote.encoded().write(to: file)
    store.reloadAfterSync()
    XCTAssertEqual(store.launchCount(for: "LOCAL"), 1)
    XCTAssertEqual(store.launchCount(for: "REMOTE"), 2)
    let saved = try LibraryStateDocument.decode(Data(contentsOf: file))
    XCTAssertEqual(saved.games["LOCAL"]?.totalLaunches, 1)
  }

  func testReloadAfterMissingOrMalformedFileKeepsMemoryAndRecoversFile() throws {
    for malformed in [false, true] {
      let (file, defaults) = try fixture()
      let store = LibraryStateStore(fileURL: file, defaults: defaults, deviceID: "local")
      store.recordLaunch(gameID: "LOCAL")
      if malformed { try Data("broken".utf8).write(to: file) }
      else { try FileManager.default.removeItem(at: file) }
      store.reloadAfterSync()
      XCTAssertEqual(store.launchCount(for: "LOCAL"), 1)
      XCTAssertEqual(try LibraryStateDocument.decode(Data(contentsOf: file)).games["LOCAL"]?.totalLaunches, 1)
    }
  }

  func testPurgedProfileDirectoryIsRecreatedWithoutLosingCounters() throws {
    let (file, defaults) = try fixture()
    let store = LibraryStateStore(fileURL: file, defaults: defaults, deviceID: "local")
    store.recordLaunch(gameID: "LOCAL")
    try FileManager.default.removeItem(at: file.deletingLastPathComponent())
    store.addPlaySeconds(10, gameID: "LOCAL")
    let saved = try LibraryStateDocument.decode(Data(contentsOf: file))
    XCTAssertEqual(saved.games["LOCAL"]?.totalLaunches, 1)
    XCTAssertEqual(saved.games["LOCAL"]?.totalPlaySeconds, 10)
  }

  func testSetFavoriteMirrorsDefaultsAndPublishesOrderedRapidEdits() throws {
    let (file, defaults) = try fixture()
    let store = LibraryStateStore(fileURL: file, defaults: defaults, deviceID: "local")
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let notification = expectation(forNotification: LibraryStateStore.favoritesChangedNotification, object: store)
    store.setFavorite(true, gameID: "TEST01", at: date)
    XCTAssertEqual((defaults.dictionary(forKey: "favorites_by_gameid") as? [String: Bool])?["TEST01"], true)
    let favored = try LibraryStateDocument.decode(Data(contentsOf: file))
    store.setFavorite(false, gameID: "TEST01", at: date)
    let unfavored = try LibraryStateDocument.decode(Data(contentsOf: file))
    XCTAssertFalse(LibraryStateDocument.merge(favored, unfavored).games["TEST01"]!.isFavorite)
    XCTAssertEqual((defaults.dictionary(forKey: "favorites_by_gameid") as? [String: Bool])?["TEST01"], false)
    wait(for: [notification], timeout: 1)
  }

  func testLocalEditBeforeReloadAdoptsAlreadyCommittedRemoteDocument() throws {
    let (file, defaults) = try fixture()
    let store = LibraryStateStore(fileURL: file, defaults: defaults, deviceID: "local")
    store.recordLaunch(gameID: "LOCAL")
    let remote = LibraryStateDocument(games: ["REMOTE": .init(launches: ["other": 2])])
    let committed = LibraryStateDocument.merge(try LibraryStateDocument.decode(Data(contentsOf: file)), remote)
    try committed.encoded().write(to: file)
    // A UI edit wins the race with the notification that would reload this file.
    store.recordLaunch(gameID: "LOCAL")
    let saved = try LibraryStateDocument.decode(Data(contentsOf: file))
    XCTAssertEqual(saved.games["LOCAL"]?.totalLaunches, 2)
    XCTAssertEqual(saved.games["REMOTE"]?.totalLaunches, 2)
  }

  func testDefaultsFavoriteTogglesWithinOneSecondRemainOrdered() throws {
    let (file, defaults) = try fixture()
    let store = LibraryStateStore(fileURL: file, defaults: defaults, deviceID: "local")
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    defaults.set(["TEST01": true], forKey: "favorites_by_gameid")
    store.importFromSharedDefaults(now: stamp)
    let favored = try LibraryStateDocument.decode(Data(contentsOf: file))
    defaults.set(["TEST01": false], forKey: "favorites_by_gameid")
    store.importFromSharedDefaults(now: stamp)
    let unfavored = try LibraryStateDocument.decode(Data(contentsOf: file))
    XCTAssertFalse(LibraryStateDocument.merge(favored, unfavored).games["TEST01"]!.isFavorite)
  }

  func testUnrelatedDefaultsEditCannotRestampStaleMirrorOverRemoteFavorite() throws {
    let (file, defaults) = try fixture()
    let store = LibraryStateStore(fileURL: file, defaults: defaults, deviceID: "local")
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    store.setFavorite(true, gameID: "TEST01", at: stamp)
    let remote = LibraryStateDocument(games: ["TEST01": .init(favorite: .init(value: false, updatedAt: stamp.addingTimeInterval(5)))])
    try remote.encoded().write(to: file)
    defaults.set(["TEST01": true, "OTHER": true], forKey: "favorites_by_gameid")
    store.importFromSharedDefaults(now: stamp.addingTimeInterval(10))
    XCTAssertFalse(store.isFavorite("TEST01"))
    XCTAssertTrue(store.isFavorite("OTHER"))
  }

  func testFavoritesNotificationStillImportsExplicitLocalChange() throws {
    let (file, defaults) = try fixture()
    let store = LibraryStateStore(fileURL: file, defaults: defaults, deviceID: "local")
    defaults.set(["TEST01": true], forKey: "favorites_by_gameid")
    store.importFromSharedDefaults()
    XCTAssertTrue(store.isFavorite("TEST01"))
    defaults.set(["TEST01": false], forKey: "favorites_by_gameid")
    store.importFromSharedDefaults()
    XCTAssertFalse(store.isFavorite("TEST01"))
  }
}
