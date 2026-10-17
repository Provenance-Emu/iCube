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

  func test_pickerCycling_wrapsBothWays() {
    let options: [(String, AnyHashable)] = [("A", AnyHashable(0)), ("B", AnyHashable(1)), ("C", AnyHashable(2))]
    XCTAssertEqual(MenuItemRole.cycled(options: options, current: AnyHashable(0), step: 1), AnyHashable(1))
    XCTAssertEqual(MenuItemRole.cycled(options: options, current: AnyHashable(2), step: 1), AnyHashable(0))
    XCTAssertEqual(MenuItemRole.cycled(options: options, current: AnyHashable(0), step: -1), AnyHashable(2))
    XCTAssertEqual(MenuItemRole.cycled(options: options, current: AnyHashable(9), step: 1), AnyHashable(0))
    XCTAssertNil(MenuItemRole.cycled(options: [], current: AnyHashable(0), step: 1))
  }

  /// A `.custom` row's own gestures never reach `MenuScreen`; a pad's A on iOS runs the item's
  /// `onCustomActivate` (MenuScreen.performActivate, device-checked). Nil by default, so existing
  /// custom rows (save-state cards) are unchanged.
  func test_customRow_carriesItsPadActivation() {
    var ran = false
    let item = MenuItem(id: "c", title: "C", role: .custom(AnyView(EmptyView())), onCustomActivate: { ran = true })
    item.onCustomActivate?()
    XCTAssertTrue(ran)
    XCTAssertNil(MenuItem(id: "d", title: "D", role: .custom(AnyView(EmptyView()))).onCustomActivate)
  }

  /// The compact tvOS picker shows the selected option's title; an unknown selection shows nothing.
  func test_selectedTitle() {
    let options: [(String, AnyHashable)] = [("Low", AnyHashable(1)), ("High", AnyHashable(2))]
    XCTAssertEqual(MenuItemRole.selectedTitle(options: options, current: AnyHashable(2)), "High")
    XCTAssertNil(MenuItemRole.selectedTitle(options: options, current: AnyHashable(3)))
  }

  func test_compactOnTV_isOffByDefault() {
    XCTAssertFalse(MenuItem(id: "p", title: "P", role: .action({})).isCompactOnTV)
    XCTAssertTrue(MenuItem(id: "q", title: "Q", role: .action({}), isCompactOnTV: true).isCompactOnTV)
  }

  // MARK: Cycle / long-press (unified menu UX spec §4.2)

  private final class Box { var value: AnyHashable = AnyHashable(200) }

  private func cycleItem(_ box: Box, longPress: MenuLongPress? = nil) -> MenuItem {
    let options: [(String, AnyHashable)] = [("Off", -1), ("2x", 200), ("4x", 400)]
    return MenuItem(
      id: "ff", title: "Fast Forward",
      role: .cycle(options: options, selection: Binding(get: { box.value }, set: { box.value = $0 })),
      description: "Tap to cycle", longPress: longPress)
  }

  func test_cycleItem_derivesLongPressFromItsOptions() {
    let box = Box()
    guard case .options(let title, let options, _)? = cycleItem(box).effectiveLongPress else {
      return XCTFail("a .cycle item with no explicit longPress offers its own options")
    }
    XCTAssertEqual(title, "Fast Forward")
    XCTAssertEqual(options.map(\.0), ["Off", "2x", "4x"])
  }

  func test_explicitLongPress_winsOverDerived() {
    let box = Box()
    var ran = false
    let item = cycleItem(box, longPress: .action { ran = true })
    if case .action(let run)? = item.effectiveLongPress { run() } else { XCTFail("explicit long press kept") }
    XCTAssertTrue(ran)
  }

  func test_currentValueTitle_forCycleToggleAndAction() {
    let box = Box()
    XCTAssertEqual(cycleItem(box).currentValueTitle, "2x")
    box.value = AnyHashable(999)
    XCTAssertEqual(cycleItem(box).currentValueTitle, "—", "an unknown value renders as a dash (spec §8)")
    let on = MenuItem(id: "m", title: "Mute", role: .toggle(.constant(true)))
    XCTAssertEqual(on.currentValueTitle, "On")
    XCTAssertNil(MenuItem(id: "a", title: "A", role: .action {}).currentValueTitle)
  }

  func test_cycled_unknownCurrent_landsOnFirstOption() {
    let options: [(String, AnyHashable)] = [("Off", -1), ("2x", 200)]
    XCTAssertEqual(MenuItemRole.cycled(options: options, current: AnyHashable(999), step: 1), AnyHashable(-1))
  }

  func test_stepper_currentValueTitle_usesTheFormat() {
    let stepper = MenuStepper(value: .constant(100), range: 1 ... 400, step: 5, format: { "\(Int($0))%" })
    XCTAssertEqual(MenuItem(id: "clock", title: "CPU Clock", role: .stepper(stepper)).currentValueTitle, "100%")
  }

  func test_section_keepsItsFooter() {
    let section = MenuSection(id: "s", header: "H", footer: "F", items: [])
    XCTAssertEqual(section.footer, "F")
    XCTAssertNil(MenuSection(id: "t", items: []).footer)
  }

  func test_item_showsChevron_defaultsOff() {
    XCTAssertFalse(MenuItem(id: "a", title: "A", role: .action({})).showsChevron)
    XCTAssertTrue(MenuItem(id: "b", title: "B", role: .action({}), showsChevron: true).showsChevron)
  }

  func test_currentValueTitle_forExplodedPicker_isSelectedOptionTitle() {
    let sel = Binding<AnyHashable>(get: { AnyHashable(2) }, set: { _ in })
    let item = MenuItem(id: "x", title: "X", role: .picker(options: [("One", 1), ("Two", 2)], selection: sel))
    XCTAssertEqual(item.currentValueTitle, "Two")
  }

  func test_currentValueTitle_forCycleOffLadder_isDash() {
    let sel = Binding<AnyHashable>(get: { AnyHashable(150) }, set: { _ in })
    let item = MenuItem(id: "x", title: "X", role: .cycle(options: [("2x", 200)], selection: sel))
    XCTAssertEqual(item.currentValueTitle, "—")
  }

  func test_disabledPicker_keepsItsValue_andIsNotFocusable() {
    let sel = Binding<AnyHashable>(get: { AnyHashable(2) }, set: { _ in })
    let item = MenuItem(id: "x", title: "X", role: .picker(options: [("One", 1), ("Two", 2)], selection: sel), isEnabled: false)
    XCTAssertEqual(item.currentValueTitle, "Two")
    XCTAssertFalse(MenuModel(sections: [MenuSection(id: "s", items: [item])]).focusableIDs.contains("x"))
  }

  /// On tvOS a left press on these rows steps the value, so the settings shell must keep focus off the
  /// sidebar while one has focus. Every other row lets left leave for the sidebar.
  func test_adjustsWithLeftRight_onlyStepperCycleAndCompactPicker() {
    var number = 100.0
    var choice: AnyHashable = 1
    var flag = false
    let numberBinding = Binding(get: { number }, set: { number = $0 })
    let choiceBinding = Binding(get: { choice }, set: { choice = $0 })
    let options: [(String, AnyHashable)] = [("One", 1), ("Two", 2)]
    let stepper = MenuItem(id: "stepper", title: "S",
                           role: .stepper(MenuStepper(value: numberBinding, range: 1 ... 400, step: 1, format: { "\($0)" })))
    let cycle = MenuItem(id: "cycle", title: "C", role: .cycle(options: options, selection: choiceBinding))
    let compact = MenuItem(id: "compact", title: "P", role: .picker(options: options, selection: choiceBinding), isCompactOnTV: true)
    let exploded = MenuItem(id: "exploded", title: "E", role: .picker(options: options, selection: choiceBinding))
    let toggle = MenuItem(id: "toggle", title: "T", role: .toggle(Binding(get: { flag }, set: { flag = $0 })))
    let action = MenuItem(id: "action", title: "A", role: .action {})
    let disabledStepper = MenuItem(id: "off", title: "O",
                                   role: .stepper(MenuStepper(value: numberBinding, range: 1 ... 400, step: 1, format: { "\($0)" })),
                                   isEnabled: false)
    let model = MenuModel(sections: [MenuSection(id: "s", items: [stepper, cycle, compact, exploded, toggle, action, disabledStepper])])

    XCTAssertTrue(model.adjustsWithLeftRight(focusID: "stepper"))
    XCTAssertTrue(model.adjustsWithLeftRight(focusID: "cycle"))
    XCTAssertTrue(model.adjustsWithLeftRight(focusID: "compact"))
    XCTAssertFalse(model.adjustsWithLeftRight(focusID: "exploded"))
    XCTAssertFalse(model.adjustsWithLeftRight(focusID: "exploded#0"), "an exploded picker's option row is a plain button")
    XCTAssertFalse(model.adjustsWithLeftRight(focusID: "toggle"))
    XCTAssertFalse(model.adjustsWithLeftRight(focusID: "action"))
    XCTAssertFalse(model.adjustsWithLeftRight(focusID: "off"), "a disabled row never has focus to hold")
    XCTAssertFalse(model.adjustsWithLeftRight(focusID: nil))
  }

  // MARK: activateInPlace / optionsPicker

  func test_activateInPlace_runsActionFlipsToggleAndStepsCycle() {
    var ran = 0
    XCTAssertTrue(MenuItem(id: "a", title: "a", role: .action { ran += 1 }).activateInPlace())
    XCTAssertTrue(MenuItem(id: "d", title: "d", role: .destructive { ran += 1 }).activateInPlace())
    XCTAssertEqual(ran, 2)

    var on = false
    let toggle = Binding(get: { on }, set: { on = $0 })
    XCTAssertTrue(MenuItem(id: "t", title: "t", role: .toggle(toggle)).activateInPlace())
    XCTAssertTrue(on)

    var value = AnyHashable(1)
    let selection = Binding(get: { value }, set: { value = $0 })
    let options: [(String, AnyHashable)] = [("One", AnyHashable(1)), ("Two", AnyHashable(2))]
    XCTAssertTrue(MenuItem(id: "c", title: "c", role: .cycle(options: options, selection: selection)).activateInPlace())
    XCTAssertEqual(value, AnyHashable(2))
    XCTAssertTrue(MenuItem(id: "c", title: "c", role: .cycle(options: options, selection: selection)).activateInPlace())
    XCTAssertEqual(value, AnyHashable(1), "wraps")
  }

  func test_activateInPlace_disabledItemDoesNothingButIsHandled() {
    var ran = false
    XCTAssertTrue(MenuItem(id: "a", title: "a", role: .action { ran = true }, isEnabled: false).activateInPlace())
    XCTAssertFalse(ran)
  }

  func test_activateInPlace_leavesPushesToTheRenderer() {
    XCTAssertFalse(MenuItem(id: "n", title: "n", role: .navigation { MenuModel() }).activateInPlace())
    XCTAssertFalse(MenuItem(id: "x", title: "x", role: .destination(AnyView(EmptyView()))).activateInPlace())
  }

  func test_optionsPicker_checksAndFocusesTheCurrentOption_pickSelectsAndCloses() {
    var value = AnyHashable(2)
    var closed = false
    let selection = Binding(get: { value }, set: { value = $0 })
    let options: [(String, AnyHashable)] = [("One", AnyHashable(1)), ("Two", AnyHashable(2))]
    let model = MenuModel.optionsPicker(itemID: "ff", options: options, selection: selection, onPick: { closed = true })
    XCTAssertEqual(model.allItems.map(\.id), ["ff#1", "ff#2"])
    XCTAssertEqual(model.allItems.map(\.icon), [nil, "checkmark"])
    XCTAssertEqual(model.focusRequest, "ff#2")
    model.item(id: "ff#1")?.activateInPlace()
    XCTAssertEqual(value, AnyHashable(1))
    XCTAssertTrue(closed)
  }
}
