// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class ModGameTableTests: XCTestCase {
  func testBundledTableCoversTheHeadlineGames() {
    let table = ModGameTable.bundled
    XCTAssertEqual(table.entry(forGameID: "GALE01")?.bananaID, 5706)
    XCTAssertEqual(table.entry(forGameID: "RMCP01")?.bananaID, 5896)
    XCTAssertEqual(table.entry(forGameID: "RSBE01")?.bananaID, 5678)
    XCTAssertGreaterThanOrEqual(table.entries.count, 40)
  }

  func testLookupMatchesRegionsAndCustomGameIDsOfTheSameTitle() {
    let table = ModGameTable.bundled
    XCTAssertEqual(table.entry(forGameID: "GALJ01")?.name, "Super Smash Bros. Melee")
    XCTAssertEqual(table.entry(forGameID: "rsbe04")?.name, "Super Smash Bros. Brawl")
    XCTAssertEqual(table.entry(forGameID: "RMCE60")?.name, "Mario Kart Wii")
  }

  func testUnknownAndShortIDsMatchNothing() {
    let table = ModGameTable.bundled
    XCTAssertNil(table.entry(forGameID: "ZZZZ99"))
    XCTAssertNil(table.entry(forGameID: "GA"))
    XCTAssertNil(table.entry(forGameID: ""))
  }

  func testEntriesAreFoundByBananaID() {
    XCTAssertEqual(ModGameTable.bundled.entry(forBananaID: 5706)?.gameIDs.first, "GALE01")
    XCTAssertNil(ModGameTable.bundled.entry(forBananaID: -1))
  }

  func testTitleCodesAreUniqueAcrossTheBundledTable() {
    var owners: [String: String] = [:]
    for entry in ModGameTable.bundled.entries {
      for id in entry.gameIDs {
        let code = String(id.prefix(3))
        if let owner = owners[code], owner != entry.name {
          XCTFail("\(code) belongs to both \(owner) and \(entry.name)")
        }
        owners[code] = entry.name
      }
    }
  }

  func testEveryGameIDIsSixUppercaseCharacters() {
    for entry in ModGameTable.bundled.entries {
      for id in entry.gameIDs {
        XCTAssertEqual(id.count, 6, "\(id) in \(entry.name)")
        XCTAssertEqual(id, id.uppercased())
      }
    }
  }

  func testDecodingFromJSON() throws {
    let json = #"{"version": 1, "games": [{"bananaID": 1, "name": "A", "iconURL": "", "gameIDs": ["AAAE01"]}]}"#
    let table = try ModGameTable(jsonData: Data(json.utf8))
    XCTAssertNil(table.entries.first?.iconURL)
    XCTAssertEqual(table.entry(forGameID: "AAAP01")?.name, "A")
  }
}
