// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class HomebrewCompatibilityTests: XCTestCase {
  private typealias Data = HomebrewTestData

  private static let dolphin = ["GameCube", "Dolphin"]

  func testGameIsUntestedUnlessTheCatalogueListsDolphin() {
    XCTAssertEqual(HomebrewCompatibility.assess(Data.title("scogger")), .untested)
    XCTAssertEqual(HomebrewCompatibility.assess(Data.title("blockamok-remix", platforms: Self.dolphin)), .listedForDolphin)
  }

  /// Genesis Plus GX is listed for Dolphin and starts there; what the user needs to know is
  /// where its ROMs go.
  func testEmulatorsAndPlayersPointAtTheirFolder() {
    let emulator = Data.title("genesis-plus-gx", category: Data.emulators, platforms: Self.dolphin)
    XCTAssertEqual(HomebrewCompatibility.assess(emulator), .usesFilesOnSDCard)
    XCTAssertEqual(HomebrewCompatibility.usesFilesOnSDCard.note(for: emulator)?.contains("Software/Homebrew/genesis-plus-gx"), true)
  }

  func testConsoleToolsAreNamedBeforeAnythingElse() {
    XCTAssertEqual(HomebrewCompatibility.assess(Data.title("dolphindepot", category: Data.utilities)), .needsConsole)
    XCTAssertEqual(HomebrewCompatibility.assess(Data.title("swiss", category: Data.utilities, platforms: Self.dolphin)), .needsConsole)
    // A controller tester is a utility too, and runs fine.
    XCTAssertEqual(HomebrewCompatibility.assess(Data.title("gc-controller-test", category: Data.utilities)), .untested)
  }

  func testOnlyUntestedHasNoNote() {
    let title = Data.title("quest")
    let all: [HomebrewCompatibility] = [.needsConsole, .usesFilesOnSDCard, .listedForDolphin]
    XCTAssertEqual(Set(all.compactMap { $0.note(for: title) }).count, all.count)
    XCTAssertNil(HomebrewCompatibility.untested.note(for: title))
  }
}
