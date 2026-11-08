// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// The iPad library dashboard's data: which game is the hero, and which saves reach the strip and the count.
final class LibraryDashboardBuilderTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_000_000)

  private func save(_ gameID: String, _ name: String, age: TimeInterval, isAuto: Bool = false, isCompatible: Bool = true) -> SaveStateInfo {
    SaveStateInfo(
      gameID: gameID,
      displayName: name,
      slot: nil,
      createdAt: nil,
      modifiedAt: now.addingTimeInterval(-age),
      sizeBytes: nil,
      versionHash: nil,
      isCompatible: isCompatible,
      path: URL(fileURLWithPath: "/saves/\(gameID)-\(name)"),
      thumbnailURL: nil,
      isAuto: isAuto
    )
  }

  private func names(_ saves: [SaveStateInfo]) -> [String] {
    saves.map(\.displayName)
  }

  // MARK: - Recent games

  func testRecentGamesAreNewestFirstAndLeaveOutGamesNotOnScreen() {
    let ids = LibraryDashboardBuilder.recentGameIDs(
      in: [LibraryGameRef(id: "GALE01"), LibraryGameRef(id: "RSBE01")],
      lastPlayed: [
        "GALE01": now.addingTimeInterval(-60),
        "RSBE01": now,
        "GSRE01": now.addingTimeInterval(60),
      ]
    )
    XCTAssertEqual(ids, ["RSBE01", "GALE01"])
  }

  func testNothingPlayedHasNoHero() {
    XCTAssertTrue(LibraryDashboardBuilder.recentGameIDs(in: [LibraryGameRef(id: "GALE01")], lastPlayed: [:]).isEmpty)
  }

  // MARK: - Recent saves

  func testRecentSavesAreNewestFirstAcrossGames() {
    let saves = LibraryDashboardBuilder.recentSaves(
      groups: [
        "GALE01": [save("GALE01", "a", age: 10), save("GALE01", "c", age: 30)],
        "RSBE01": [save("RSBE01", "b", age: 20)],
      ],
      visibleGameIDs: ["GALE01", "RSBE01"]
    )
    XCTAssertEqual(names(saves), ["a", "b", "c"])
  }

  func testAutoStateStaysOffTheStrip() {
    let saves = LibraryDashboardBuilder.recentSaves(
      groups: ["GALE01": [save("GALE01", "Continue", age: 1, isAuto: true), save("GALE01", "Slot 1", age: 50)]],
      visibleGameIDs: ["GALE01"]
    )
    XCTAssertEqual(names(saves), ["Slot 1"])
  }

  func testRecentSavesFollowThePlatformFilter() {
    let saves = LibraryDashboardBuilder.recentSaves(
      groups: ["GALE01": [save("GALE01", "gc", age: 1)], "RSBE01": [save("RSBE01", "wii", age: 2)]],
      visibleGameIDs: ["RSBE01"]
    )
    XCTAssertEqual(names(saves), ["wii"])
  }

  func testOneGameCannotFillTheStrip() {
    let many = (0 ..< 10).map { save("GALE01", "gc\($0)", age: TimeInterval($0)) }
    let saves = LibraryDashboardBuilder.recentSaves(
      groups: ["GALE01": many, "RSBE01": [save("RSBE01", "wii", age: 100)]],
      visibleGameIDs: ["GALE01", "RSBE01"],
      perGame: 2
    )
    XCTAssertEqual(names(saves), ["gc0", "gc1", "wii"])
  }

  func testStripIsCapped() {
    let many = (0 ..< 5).map { index in save("G\(index)", "s\(index)", age: TimeInterval(index)) }
    let groups = Dictionary(uniqueKeysWithValues: many.map { ($0.gameID, [$0]) })
    let saves = LibraryDashboardBuilder.recentSaves(groups: groups, visibleGameIDs: Set(groups.keys), limit: 2)
    XCTAssertEqual(names(saves), ["s0", "s1"])
  }

  func testIncompatibleSavesStayVisible() {
    let saves = LibraryDashboardBuilder.recentSaves(
      groups: ["GALE01": [save("GALE01", "old", age: 1, isCompatible: false)]],
      visibleGameIDs: ["GALE01"]
    )
    XCTAssertEqual(names(saves), ["old"])
  }

  // MARK: - Count and resume

  func testSaveCountMatchesTheBrowserIncludingAutoStates() {
    let groups = [
      "GALE01": [save("GALE01", "Continue", age: 1, isAuto: true), save("GALE01", "a", age: 2)],
      "RSBE01": [save("RSBE01", "b", age: 3)],
    ]
    XCTAssertEqual(LibraryDashboardBuilder.saveCount(groups: groups), 3)
  }

  func testResumeNeedsTheSettingAndAnAutoState() {
    let groups = ["GALE01": [save("GALE01", "Continue", age: 1, isAuto: true)], "RSBE01": [save("RSBE01", "a", age: 2)]]
    XCTAssertTrue(LibraryDashboardBuilder.canResume(gameID: "GALE01", groups: groups, resumeEnabled: true))
    XCTAssertFalse(LibraryDashboardBuilder.canResume(gameID: "GALE01", groups: groups, resumeEnabled: false))
    XCTAssertFalse(LibraryDashboardBuilder.canResume(gameID: "RSBE01", groups: groups, resumeEnabled: true))
    XCTAssertFalse(LibraryDashboardBuilder.canResume(gameID: "SOUE01", groups: groups, resumeEnabled: true))
  }
}
