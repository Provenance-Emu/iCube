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
    #if os(iOS)
    XCTAssertEqual(model().allItems.map(\.id), ["load-main-menu", "language", "slot-b-microphone"])
    XCTAssertEqual(model().sections.map(\.id), ["general", "system-language", "peripherals"])
    XCTAssertEqual(model().sections.map(\.header), ["General", nil, "Peripherals"])
    XCTAssertEqual(model().allItems.map(\.title), ["Load GameCube Main Menu", "System Language", "Microphone in Slot B"])
    #else
    XCTAssertEqual(model().allItems.map(\.id), ["load-main-menu", "language"])
    XCTAssertEqual(model().sections.map(\.id), ["general", "system-language"])
    XCTAssertEqual(model().sections.map(\.header), ["General", nil])
    XCTAssertEqual(model().allItems.map(\.title), ["Load GameCube Main Menu", "System Language"])
    #endif
  }

  func test_slotBMicrophone_reflectsTheState_andEmitsItsOwnChange_iOSOnly() {
    #if os(iOS)
    for shown in [true, false] {
      var s = ConfigGameCubeState()
      s.slotBMicrophone = shown
      guard case .toggle(let binding)? = model(s).item(id: "slot-b-microphone")?.role else { return XCTFail("not a toggle") }
      XCTAssertEqual(binding.wrappedValue, shown)
      changes = []
      binding.wrappedValue = !shown
      XCTAssertEqual(changes, [.slotBMicrophone(!shown)])
    }
    #else
    XCTAssertNil(model().item(id: "slot-b-microphone"))
    #endif
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

  func test_displayedLanguage_preservesConfigValue_andClampsOldBugValues() {
    for value in 0 ... 5 {
      XCTAssertEqual(ConfigGameCubeState.displayedLanguage(stored: value), value)
    }
    for value in [-1, 6, 99] {
      XCTAssertEqual(ConfigGameCubeState.displayedLanguage(stored: value), 0)
    }
  }

  func test_defaults_matchTheOldViewsState() {
    XCTAssertEqual(ConfigGameCubeState(), ConfigGameCubeState(loadMainMenu: true, language: 0))
  }
}
