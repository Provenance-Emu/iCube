// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class HomebrewCompatibilityTests: XCTestCase {
  private typealias Data = HomebrewTestData

  private static let dolphin = ["GameCube", "Dolphin"]

  func testGameOnItsOwnIsUntestedUnlessTheCatalogueListsDolphin() {
    XCTAssertEqual(HomebrewCompatibility.assess(Data.title("scogger"), packagedDataFiles: nil), .untested)
    XCTAssertEqual(HomebrewCompatibility.assess(Data.title("scogger"), packagedDataFiles: 0), .untested)
    XCTAssertEqual(HomebrewCompatibility.assess(Data.title("blockamok-remix", platforms: Self.dolphin), packagedDataFiles: 0),
                   .listedForDolphin)
  }

  /// FruitY and Nicky Boum: games, so the category says nothing, but the package does.
  func testPackagedDataFilesOutrankTheCatalogue() {
    XCTAssertEqual(HomebrewCompatibility.assess(Data.title("fruity"), packagedDataFiles: 4), .needsPackagedFiles)
    XCTAssertEqual(HomebrewCompatibility.assess(Data.title("nicky", platforms: Self.dolphin), packagedDataFiles: 64),
                   .needsPackagedFiles)
  }

  /// Genesis Plus GX is listed for Dolphin and starts there, but its ROMs come from an SD card.
  func testEmulatorsAndPlayersNeedAnSDCardEvenWhenListedForDolphin() {
    let emulator = Data.title("genesis-plus-gx", category: Data.emulators, platforms: Self.dolphin)
    XCTAssertEqual(HomebrewCompatibility.assess(emulator, packagedDataFiles: nil), .needsSDCard)
    XCTAssertEqual(HomebrewCompatibility.assess(emulator, packagedDataFiles: 0), .needsSDCard)
  }

  func testConsoleToolsAreNamedBeforeAnythingElse() {
    let depot = Data.title("dolphindepot", category: Data.utilities)
    XCTAssertEqual(HomebrewCompatibility.assess(depot, packagedDataFiles: nil), .needsConsole)
    let swiss = Data.title("swiss", category: Data.utilities, platforms: Self.dolphin)
    XCTAssertEqual(HomebrewCompatibility.assess(swiss, packagedDataFiles: 1), .needsConsole)
    // A controller tester is a utility too, and runs fine.
    XCTAssertEqual(HomebrewCompatibility.assess(Data.title("gc-controller-test", category: Data.utilities),
                                                packagedDataFiles: 0), .untested)
  }

  func testOnlyUntestedHasNoNote() {
    let all: [HomebrewCompatibility] = [.needsConsole, .needsPackagedFiles, .needsSDCard, .listedForDolphin]
    XCTAssertEqual(Set(all.compactMap(\.note)).count, all.count)
    XCTAssertNil(HomebrewCompatibility.untested.note)
  }
}
