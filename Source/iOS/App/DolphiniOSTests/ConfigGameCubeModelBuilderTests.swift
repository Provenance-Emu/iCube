// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class ConfigGameCubeModelBuilderTests: XCTestCase {
  private var changes: [ConfigGameCubeChange] = []
  private func model(_ state: ConfigGameCubeState = ConfigGameCubeState()) -> MenuModel {
    ConfigGameCubeModelBuilder.make(state: state) { self.changes.append($0) }
  }

  func test_rowOrder_andSections() {
    XCTAssertEqual(model().allItems.map(\.id), ["load-main-menu", "language"])
    XCTAssertEqual(model().sections.map(\.id), ["general", "system-language"])
    XCTAssertEqual(model().sections.map(\.header), ["General", nil])
    XCTAssertEqual(model().allItems.map(\.title), ["Load GameCube Main Menu", "System Language"])
  }

  func test_everyRow_hasADescription() {
    for item in model().allItems { XCTAssertFalse((item.description ?? "").isEmpty, item.id) }
  }

  func test_loadMainMenu_reflectsTheState_andEmitsItsOwnChange() {
    for shown in [true, false] {
      guard case .toggle(let binding)? = model(ConfigGameCubeState(loadMainMenu: shown, language: 0)).item(id: "load-main-menu")?.role else { return XCTFail("not a toggle") }
      XCTAssertEqual(binding.wrappedValue, shown)
      for value in [true, false] {
        changes = []
        binding.wrappedValue = value
        XCTAssertEqual(changes, [.loadMainMenu(value)])
      }
    }
  }

  func test_language_listsTheSixGameCubeLanguages_inIndexOrder() {
    guard case .cycle(let options, _)? = model().item(id: "language")?.role else { return XCTFail("not a cycle") }
    XCTAssertEqual(options.map(\.0), ["English", "German", "French", "Spanish", "Italian", "Dutch"])
    XCTAssertEqual(options.map { $0.1.base as? Int }, [0, 1, 2, 3, 4, 5])
  }

  func test_language_emitsItsOwnChange() {
    guard case .cycle(_, let selection)? = model().item(id: "language")?.role else { return XCTFail("not a cycle") }
    selection.wrappedValue = AnyHashable(3)
    XCTAssertEqual(changes, [.language(3)])
  }

  func test_language_showsTheStoredLanguage() {
    let cases: [(Int, String)] = [(0, "English"), (1, "German"), (2, "French"), (3, "Spanish"), (4, "Italian"), (5, "Dutch")]
    for (value, title) in cases {
      XCTAssertEqual(model(ConfigGameCubeState(loadMainMenu: true, language: value)).item(id: "language")?.currentValueTitle, title)
    }
  }

  func test_language_aValueMatchingNoOptionIsInsertedRatherThanShownAsADash() {
    guard case .cycle(let options, _)? = model(ConfigGameCubeState(loadMainMenu: true, language: 9)).item(id: "language")?.role else { return XCTFail("not a cycle") }
    XCTAssertEqual(options.count, 7)
    XCTAssertEqual(options.last?.1.base as? Int, 9)
  }

  func test_gcLanguage_fromThePreferredLanguageCode() {
    let cases: [(String, Int)] = [("en-US", 0), ("de-DE", 1), ("fr", 2), ("es-MX", 3), ("it", 4), ("nl-NL", 5), ("ja-JP", 0), ("zh-Hans", 0), ("", 0), ("DE", 1), ("FR-ca", 2)]
    for (code, expected) in cases { XCTAssertEqual(ConfigGameCubeState.gcLanguage(forPreferredLanguage: code), expected, code) }
  }

  func test_displayedLanguage_trustsAStoredValue_clampsOldBugValues_andDerivesWhenUnset() {
    let cases: [(Bool, Int, String, Int)] = [
      (true, 3, "de", 3), (true, 0, "de", 0), (true, 5, "en", 5),
      (true, 6, "de", 0), (true, -1, "de", 0), (true, 99, "fr", 0),
      (false, 0, "fr", 2), (false, 4, "nl", 5), (false, 0, "ja", 0),
    ]
    for (isSet, stored, code, expected) in cases {
      XCTAssertEqual(ConfigGameCubeState.displayedLanguage(isSet: isSet, stored: stored, preferredLanguage: code), expected, "\(isSet) \(stored) \(code)")
    }
  }

  func test_languageSeed_onlyWhenNeverChosen() {
    let cases: [(Bool, String, Int?)] = [(false, "nl", 5), (false, "en", 0), (false, "", 0), (true, "nl", nil), (true, "en", nil)]
    for (isSet, code, expected) in cases {
      XCTAssertEqual(ConfigGameCubeState.languageSeed(isSet: isSet, preferredLanguage: code), expected, "\(isSet) \(code)")
    }
  }

  func test_defaults_matchTheOldViewsState() {
    XCTAssertEqual(ConfigGameCubeState(), ConfigGameCubeState(loadMainMenu: true, language: 0))
  }
}
