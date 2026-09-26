// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class MenuModelTests: XCTestCase {

  private func item(_ id: String, enabled: Bool = true) -> MenuItem {
    MenuItem(id: id, title: id, role: .action({}), isEnabled: enabled)
  }

  private func makeModel() -> MenuModel {
    MenuModel(sections: [
      MenuSection(id: "s1", header: "One", items: [item("a"), item("b", enabled: false), item("c")]),
      MenuSection(id: "s2", header: "Two", items: [item("d"), item("e")]),
      MenuSection(id: "s3", header: "Three", items: [item("f")]),
    ])
  }

  // MARK: Construction / basic lookup

  func test_allItems_flattensSectionsInOrder() {
    let model = makeModel()
    XCTAssertEqual(model.allItems.map(\.id), ["a", "b", "c", "d", "e", "f"])
  }

  func test_focusableIDs_excludesDisabledItems() {
    let model = makeModel()
    XCTAssertEqual(model.focusableIDs, ["a", "c", "d", "e", "f"], "b is disabled and must not be focusable")
  }

  func test_item_lookupByID() {
    let model = makeModel()
    XCTAssertEqual(model.item(id: "d")?.title, "d")
    XCTAssertNil(model.item(id: "nope"))
  }

  func test_sectionContainingItem() {
    let model = makeModel()
    XCTAssertEqual(model.section(containing: "d")?.id, "s2")
    XCTAssertEqual(model.sectionIndex(containing: "f"), 2)
    XCTAssertNil(model.section(containing: "nope"))
  }

  func test_badge_isCarriedVerbatim_noRecomputation() {
    // §8 "Badge cost": the model only carries a pre-formatted string; nothing
    // in MenuModel/MenuItem computes it. This test pins that the value passed
    // in comes back out unchanged, which is the whole contract.
    let withBadge = MenuItem(id: "cheats", title: "Cheats", role: .action({}), badge: "3 active")
    XCTAssertEqual(withBadge.badge, "3 active")
  }

  // MARK: Section-jump lookup (feeds MenuFocusRouter's shoulder handling)

  func test_firstFocusableID_jumpsToNextSection() {
    let model = makeModel()
    XCTAssertEqual(model.firstFocusableID(sectionOffsetFrom: "a", by: 1), "d")
  }

  func test_firstFocusableID_jumpsToPreviousSection() {
    let model = makeModel()
    XCTAssertEqual(model.firstFocusableID(sectionOffsetFrom: "d", by: -1), "a")
  }

  func test_firstFocusableID_atLastSection_returnsNilNotWrap() {
    let model = makeModel()
    XCTAssertNil(model.firstFocusableID(sectionOffsetFrom: "f", by: 1),
                 "nil means no-op; MenuFocusRouter is what keeps focus on f")
  }

  func test_firstFocusableID_atFirstSection_returnsNilNotWrap() {
    let model = makeModel()
    XCTAssertNil(model.firstFocusableID(sectionOffsetFrom: "a", by: -1))
  }

  func test_firstFocusableID_skipsSectionsWithNoFocusableItems() {
    let model = MenuModel(sections: [
      MenuSection(id: "s1", items: [item("a")]),
      MenuSection(id: "s2", items: [item("b", enabled: false)]),
      MenuSection(id: "s3", items: [item("c")]),
    ])
    XCTAssertEqual(model.firstFocusableID(sectionOffsetFrom: "a", by: 1), "c", "s2 has nothing focusable; skip to s3")
  }

  func test_firstFocusableID_unknownItem_fallsBackToFirstFocusable() {
    let model = makeModel()
    XCTAssertEqual(model.firstFocusableID(sectionOffsetFrom: "nope", by: 1), "a")
  }

  // MARK: Role plumbing (constructors don't reach into bridges — §1)

  func test_toggleRole_readsAndWritesThroughBinding() {
    var stored = false
    let binding = Binding(get: { stored }, set: { stored = $0 })
    let toggleItem = MenuItem(id: "mute", title: "Mute", role: .toggle(binding))
    guard case .toggle(let readBack) = toggleItem.role else {
      return XCTFail("expected .toggle role")
    }
    readBack.wrappedValue = true
    XCTAssertTrue(stored, "the model's binding must be the same one passed in, not a copy")
  }
}
