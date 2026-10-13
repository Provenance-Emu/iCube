// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class SettingsRootModelBuilderTests: XCTestCase {
  func test_sections_inSpecOrder() {
    let sections = SettingsRootModelBuilder.sections(isIOS: true, achievements: true)
    XCTAssertEqual(sections.map(\.id), ["general", "graphics", "audio", "consoles", "controllers", "performance", "sync-network", "privacy", "about"])
  }

  func test_everyEntry_hasDescriptionAndUniqueID() {
    let entries = SettingsRootModelBuilder.sections(isIOS: true, achievements: true).flatMap(\.entries)
    XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
    for entry in entries { XCTAssertFalse(entry.description.isEmpty, entry.id) }
  }

  func test_migratedLeaves_exposeTheirModels() {
    let entries = SettingsRootModelBuilder.sections(isIOS: true, achievements: true).flatMap(\.entries)
    for id in ["graphics-hacks", "graphics-enhancements", "graphics-video", "graphics-advanced", "performance-tuning", "advanced", "interface", "general", "console-gamecube", "console-wii", "audio", "debug", "privacy"] {
      XCTAssertNotNil(entries.first { $0.id == id }?.makeModel, id)
    }
  }

  func test_model_hasOneChevronActionRowPerEntry_inSectionOrder() {
    let sections = SettingsRootModelBuilder.sections(isIOS: false, achievements: false)
    let model = SettingsRootModelBuilder.model(sections: sections, onSelect: { _ in })
    XCTAssertEqual(model.sections.map(\.id), sections.map(\.id))
    XCTAssertEqual(model.allItems.map(\.id), sections.flatMap(\.entries).map(\.id))
    for item in model.allItems {
      XCTAssertTrue(item.showsChevron, item.id)
      guard case .action = item.role else { XCTFail("\(item.id) should be an .action row"); continue }
    }
  }

  func test_selectingARow_reportsItsEntry() {
    var selected: [String] = []
    let sections = SettingsRootModelBuilder.sections(isIOS: true, achievements: false)
    let model = SettingsRootModelBuilder.model(sections: sections, onSelect: { selected.append($0.id) })
    guard case .action(let run)? = model.item(id: "graphics-hacks")?.role else { return XCTFail("action") }
    run()
    XCTAssertEqual(selected, ["graphics-hacks"])
  }

  /// A leaf that is not a MenuScreen needs `.padBackNavigation()`; one that hosts a MenuScreen must not get it twice.
  func test_hostsMenuScreen_isExactlyTheMigratedLeavesAndControllers() {
    let entries = SettingsRootModelBuilder.sections(isIOS: true, achievements: true).flatMap(\.entries)
    let hosting = Set(entries.filter(\.hostsMenuScreen).map(\.id))
    XCTAssertEqual(hosting, ["graphics-video", "graphics-enhancements", "graphics-hacks", "graphics-advanced", "performance-tuning", "controllers", "advanced", "interface", "general", "console-gamecube", "console-wii", "audio", "debug", "privacy"])
  }

  func test_entriesAreHashableByID() {
    let entries = SettingsRootModelBuilder.sections(isIOS: true, achievements: false).flatMap(\.entries)
    XCTAssertEqual(Set(entries).count, entries.count)
    XCTAssertEqual(entries[0], SettingsRootModelBuilder.sections(isIOS: false, achievements: false).flatMap(\.entries)[0])
  }

  func test_tvScreenshotScript_leafIDs_exist() {
    let ids = Set(SettingsRootModelBuilder.sections(isIOS: false, achievements: false).flatMap(\.entries).map(\.id))
    for id in ["general", "interface", "advanced", "graphics-video", "graphics-enhancements", "graphics-hacks",
               "graphics-advanced", "shaders", "audio", "console-gamecube", "console-wii", "controllers",
               "performance-tuning", "debug", "web-ui", "icloud", "nearby", "privacy", "about"] {
      XCTAssertTrue(ids.contains(id), id)
    }
  }

  func test_debugLeafNil_omitsTheDebugEntry() {
    let ids = SettingsRootModelBuilder.sections(isIOS: true, achievements: false, debugLeaf: nil).flatMap(\.entries).map(\.id)
    XCTAssertFalse(ids.contains("debug"))
    XCTAssertTrue(ids.contains("performance-tuning"))
  }

  func test_debugLeafJitOnly_keepsTheEntry() {
    let ids = SettingsRootModelBuilder.sections(isIOS: true, achievements: false, debugLeaf: .jitOnly).flatMap(\.entries).map(\.id)
    XCTAssertTrue(ids.contains("debug"))
  }
}
