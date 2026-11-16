// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import PVLibrarySnapshot
import XCTest
@testable import iCube

private func game(_ id: String, lastPlayed: Date?) -> LibrarySnapshotGame {
  LibrarySnapshotGame(
    id: id, title: id, filePath: "/tmp/\(id).iso", platform: .gamecube,
    gametdbID: nil, region: nil, lastPlayed: lastPlayed, isFavorite: false, coverFilename: nil
  )
}

final class ResumeLastGameTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testEmptyLibraryOnlyOpensTheApp() {
    XCTAssertEqual(ResumeLastGame.decide(recentlyPlayed: []), .openAppOnly)
    XCTAssertEqual(ResumeLastGame.decide(snapshot: .empty), .openAppOnly)
  }

  func testSingleGameIsResumed() {
    XCTAssertEqual(
      ResumeLastGame.decide(recentlyPlayed: [game("GALE01", lastPlayed: now)]),
      .resume(gameID: "GALE01")
    )
  }

  func testNewestListEntryWinsWhenOrderedNewestFirst() {
    let list = [
      game("GALE01", lastPlayed: now),
      game("RSBE01", lastPlayed: now.addingTimeInterval(-60)),
    ]
    XCTAssertEqual(ResumeLastGame.decide(recentlyPlayed: list), .resume(gameID: "GALE01"))
  }

  func testNewestDateWinsEvenWhenTheListIsOutOfOrder() {
    let list = [
      game("RSBE01", lastPlayed: now.addingTimeInterval(-3_600)),
      game("GALE01", lastPlayed: now),
      game("GM4E01", lastPlayed: now.addingTimeInterval(-60)),
    ]
    XCTAssertEqual(ResumeLastGame.decide(recentlyPlayed: list), .resume(gameID: "GALE01"))
  }

  func testTieKeepsTheEarlierListEntry() {
    let list = [game("GALE01", lastPlayed: now), game("RSBE01", lastPlayed: now)]
    XCTAssertEqual(ResumeLastGame.decide(recentlyPlayed: list), .resume(gameID: "GALE01"))
  }

  func testGamesWithoutADateFallBackToListOrder() {
    let list = [game("GALE01", lastPlayed: nil), game("RSBE01", lastPlayed: nil)]
    XCTAssertEqual(ResumeLastGame.decide(recentlyPlayed: list), .resume(gameID: "GALE01"))
  }

  func testADatedGameBeatsAnUndatedOneEvenWhenListedLater() {
    let list = [game("GALE01", lastPlayed: nil), game("RSBE01", lastPlayed: now)]
    XCTAssertEqual(ResumeLastGame.decide(recentlyPlayed: list), .resume(gameID: "RSBE01"))
  }

  func testGamesWithAnEmptyIDAreNeverResumed() {
    XCTAssertEqual(ResumeLastGame.decide(recentlyPlayed: [game("", lastPlayed: now)]), .openAppOnly)
    let list = [game("", lastPlayed: now), game("GALE01", lastPlayed: now.addingTimeInterval(-60))]
    XCTAssertEqual(ResumeLastGame.decide(recentlyPlayed: list), .resume(gameID: "GALE01"))
  }

  /// The control intent runs from code that only knows the shared key; the app reads it back
  /// through `PendingGameLaunchStore`. They must agree.
  func testPendingKeyIsTheOneThePendingStoreConsumes() {
    let suite = "icube.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("GALE01", forKey: PendingGameLaunchKey.defaultsKey)
    XCTAssertEqual(PendingGameLaunchStore.consume(from: defaults), "GALE01")
  }
}

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
final class GameActivityStateTests: XCTestCase {
  func testUpdateKeepsTitleAndSubtitle() {
    let started = GameActivityAttributes.ContentState(
      title: "Mario Kart Wii", subtitle: "Nintendo", isPaused: false, elapsedSeconds: 0
    )
    let ticked = started.updating(isPaused: true, elapsedSeconds: 42)
    XCTAssertEqual(ticked.title, "Mario Kart Wii")
    XCTAssertEqual(ticked.subtitle, "Nintendo")
    XCTAssertTrue(ticked.isPaused)
    XCTAssertEqual(ticked.elapsedSeconds, 42)
  }
}
#endif
