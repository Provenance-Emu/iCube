// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class CheatCategoryTests: XCTestCase {

  private func cheat(_ name: String, enabled: Bool = false) -> CheatItem {
    CheatItem(id: name, name: name, type: "Gecko Code", enabled: enabled, isGecko: true, index: 0)
  }

  // MARK: classify

  func test_classify_keywords() {
    let cases: [(String, CheatCategory)] = [
      ("Infinite Lives", .infinite),
      ("Unlimited Ammo", .infinite),
      ("Inf Health", .infinite),
      ("Rupees Never Decrease", .infinite),
      ("Max Coins", .max),
      ("999 Rupees", .max),
      ("Maximum Stats", .max),
      ("Unlock All Characters", .unlock),
      ("Have All Items", .unlock),
      ("All Levels Open", .unlock),
      ("Invincibility", .invincible),
      ("God Mode", .invincible),
      ("No Damage Taken", .invincible),
      ("16:9 Widescreen", .display),
      ("60 FPS", .display),
      ("Force Progressive Scan", .display),
      ("Classic Controller Support", .controls),
      ("Nunchuk Swap", .controls),
      ("Debug Menu", .debug),
      ("Enable Debug Mode", .debug),
      ("Skip Intro Movie", .unlock),
      ("Moon Jump", .other),
      ("Play as Luigi", .other),
    ]
    for (name, expected) in cases {
      XCTAssertEqual(CheatCategory.classify(name: name), expected, name)
    }
  }

  /// Short keywords match whole words only.
  func test_classify_shortWordsNeedBoundaries() {
    XCTAssertEqual(CheatCategory.classify(name: "Climax Mode"), .other, "'max' inside 'Climax' must not fire")
    XCTAssertEqual(CheatCategory.classify(name: "Ball Size"), .other, "'all' inside 'Ball' must not fire")
    XCTAssertEqual(CheatCategory.classify(name: "Max Lives"), .max)
    XCTAssertEqual(CheatCategory.classify(name: "All Stars"), .unlock)
  }

  /// The more specific rule wins when a name hits two.
  func test_classify_precedence() {
    XCTAssertEqual(CheatCategory.classify(name: "Enable Debug Menu"), .debug)
    XCTAssertEqual(CheatCategory.classify(name: "Enable 16:9"), .display)
    XCTAssertEqual(CheatCategory.classify(name: "Infinite Health (God Mode)"), .invincible)
  }

  func test_classify_isCaseInsensitive() {
    XCTAssertEqual(CheatCategory.classify(name: "INFINITE LIVES"), .infinite)
  }

  // MARK: CheatFilter

  func test_filter_available_onlyListsPresentCategoriesInOrder() {
    let cheats = [cheat("Unlock Everything"), cheat("Infinite Lives"), cheat("Moon Jump")]
    XCTAssertEqual(CheatFilter.available(in: cheats), [.all, .category(.infinite), .category(.unlock), .category(.other)])
  }

  func test_filter_available_includesEnabledOnlyWhenSomethingIsOn() {
    XCTAssertFalse(CheatFilter.available(in: [cheat("Infinite Lives")]).contains(.enabled))
    XCTAssertTrue(CheatFilter.available(in: [cheat("Infinite Lives", enabled: true)]).contains(.enabled))
  }

  func test_filter_available_emptyListIsJustAll() {
    XCTAssertEqual(CheatFilter.available(in: []), [.all])
  }

  func test_filter_isWorthShowing_needsTwoRealAlternatives() {
    XCTAssertFalse(CheatFilter.isWorthShowing([.all]))
    XCTAssertFalse(CheatFilter.isWorthShowing([.all, .category(.other)]), "All and Other would list the same rows")
    XCTAssertTrue(CheatFilter.isWorthShowing([.all, .enabled, .category(.other)]))
    XCTAssertTrue(CheatFilter.isWorthShowing([.all, .category(.infinite), .category(.other)]))
  }

  func test_filter_matchesAndCounts() {
    let cheats = [cheat("Infinite Lives", enabled: true), cheat("Infinite Ammo"), cheat("Moon Jump", enabled: true)]
    XCTAssertEqual(CheatFilter.all.count(in: cheats), 3)
    XCTAssertEqual(CheatFilter.enabled.count(in: cheats), 2)
    XCTAssertEqual(CheatFilter.category(.infinite).count(in: cheats), 2)
    XCTAssertEqual(CheatFilter.category(.other).count(in: cheats), 1)
    XCTAssertEqual(CheatFilter.category(.debug).count(in: cheats), 0)
  }

  func test_filter_idRoundTrips() {
    let filters: [CheatFilter] = [.all, .enabled] + CheatCategory.allCases.map(CheatFilter.category)
    for filter in filters {
      XCTAssertEqual(CheatFilter(id: filter.id), filter, filter.id)
    }
    XCTAssertNil(CheatFilter(id: "category.nope"))
    XCTAssertNil(CheatFilter(id: "bogus"))
  }

  // MARK: CheatItem labels

  func test_sourceLine_andSummary() {
    var item = cheat("Infinite Lives")
    XCTAssertEqual(item.sourceLine, "Gecko")
    item.creator = "Ralf"
    XCTAssertEqual(item.sourceLine, "Gecko · by Ralf")
    item.isBuiltIn = true
    XCTAssertEqual(item.sourceLine, "Gecko · Built-in", "built-in wins over creator")

    item.notes = "\n  \nInfinite Lives\nPress Z to refill\n"
    XCTAssertEqual(item.summary, "Press Z to refill", "skips blanks and a line that only repeats the name")
    item.notes = "Infinite Lives"
    XCTAssertNil(item.summary)
    item.notes = nil
    XCTAssertNil(item.summary)
  }
}
