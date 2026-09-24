// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

final class LastPlayedStoreTests: XCTestCase {
  private var suite: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suite = "icube.tests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
    super.tearDown()
  }

  func testRecordAndRead() {
    let d = Date(timeIntervalSince1970: 1_700_000_000)
    LastPlayedStore.record(gameID: "GALE01", date: d, in: defaults)
    XCTAssertEqual(LastPlayedStore.lastPlayed(gameID: "GALE01", in: defaults), d)
    XCTAssertNil(LastPlayedStore.lastPlayed(gameID: "NOPE00", in: defaults))
    XCTAssertEqual(LastPlayedStore.all(in: defaults).count, 1)
  }

  func testEmptyGameIDIgnored() {
    LastPlayedStore.record(gameID: "", in: defaults)
    XCTAssertTrue(LastPlayedStore.all(in: defaults).isEmpty)
  }

  func testMigrationCopiesOnceAndDoesNotOverwrite() {
    let source = UserDefaults(suiteName: suite + ".src")!
    defer { source.removePersistentDomain(forName: suite + ".src") }
    source.set(["GALE01": true], forKey: "favorites_by_gameid")
    source.set(["GALE01": 1_700_000_000.0], forKey: "last_played_v1")
    SharedDefaults.migrateIfNeeded(from: source, to: defaults)
    XCTAssertEqual(defaults.dictionary(forKey: "favorites_by_gameid") as? [String: Bool], ["GALE01": true])
    XCTAssertEqual(defaults.dictionary(forKey: "last_played_v1") as? [String: Double], ["GALE01": 1_700_000_000.0])
    source.set(["OTHER1": true], forKey: "favorites_by_gameid")
    source.set(["OTHER1": 1_800_000_000.0], forKey: "last_played_v1")
    SharedDefaults.migrateIfNeeded(from: source, to: defaults)
    XCTAssertEqual(defaults.dictionary(forKey: "favorites_by_gameid") as? [String: Bool], ["GALE01": true], "second run is a no-op")
    XCTAssertEqual(defaults.dictionary(forKey: "last_played_v1") as? [String: Double], ["GALE01": 1_700_000_000.0], "second run is a no-op")
  }
}
