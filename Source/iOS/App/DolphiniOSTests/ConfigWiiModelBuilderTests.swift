// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class ConfigWiiModelBuilderTests: XCTestCase {
  private var changes: [ConfigWiiChange] = []
  private func model(_ state: ConfigWiiState = ConfigWiiState()) -> MenuModel {
    ConfigWiiModelBuilder.make(state: state) { self.changes.append($0) }
  }
  private func state(_ edit: (inout ConfigWiiState) -> Void) -> ConfigWiiState {
    var s = ConfigWiiState()
    edit(&s)
    return s
  }

  func test_rowOrder_sectionsAndFooters() {
    XCTAssertEqual(model().allItems.map(\.id), [
      "pal60", "aspect-ratio",
      "screensaver", "language", "sound-mode",
      "sensor-bar-position", "sensor-bar-sensitivity", "speaker-volume", "rumble", "touchpad-ir-follow",
      "skylander-portal", "usb-keyboard", "wiilink", "sd-folder-sync",
    ])
    XCTAssertEqual(model().sections.map(\.id), ["video", "general", "wii-remotes", "usb-sd"])
    XCTAssertEqual(model().sections.map(\.header), ["Video", "General", "Wii Remotes", "USB / SD"])
    XCTAssertEqual(model().sections.map(\.footer), [
      "These write to the emulated Wii's SYSCONF, so they affect Wii titles only and persist like a real Wii would.",
      nil, nil,
      "Emulated Wii peripherals. None of these affect emulation speed.",
    ])
  }

  func test_everyRow_hasADescription() {
    for item in model().allItems { XCTAssertFalse((item.description ?? "").isEmpty, item.id) }
  }

  func test_noSDCardToggles_theOldViewNeverShowedThem() {
    XCTAssertNil(model().item(id: "sd-card"))
    XCTAssertNil(model().item(id: "sd-writes"))
  }

  func test_everyToggleRow_emitsItsOwnChange() {
    let expected: [(String, (Bool) -> ConfigWiiChange)] = [
      ("pal60", { .pal60($0) }), ("screensaver", { .screensaver($0) }), ("rumble", { .wiimoteRumble($0) }),
      ("touchpad-ir-follow", { .touchpadIRFollowWithoutClick($0) }), ("skylander-portal", { .skylanderPortal($0) }),
      ("usb-keyboard", { .keyboard($0) }), ("wiilink", { .wiilink($0) }), ("sd-folder-sync", { .sdFolderSync($0) }),
    ]
    let m = model()
    for (id, change) in expected {
      guard case .toggle(let binding)? = m.item(id: id)?.role else { XCTFail("\(id) is not a toggle"); continue }
      for value in [true, false] {
        changes = []
        binding.wrappedValue = value
        XCTAssertEqual(changes, [change(value)], id)
      }
    }
  }

  func test_toggleRows_reflectTheState() {
    let on = state { $0.pal60 = true; $0.screensaver = true; $0.wiimoteRumble = false; $0.touchpadIRFollowWithoutClick = true
      $0.skylanderPortal = true; $0.keyboard = true; $0.wiilink = true; $0.sdFolderSync = true }
    let expected: [(String, Bool)] = [
      ("pal60", true), ("screensaver", true), ("rumble", false), ("touchpad-ir-follow", true),
      ("skylander-portal", true), ("usb-keyboard", true), ("wiilink", true), ("sd-folder-sync", true),
    ]
    for (id, value) in expected {
      guard case .toggle(let binding)? = model(on).item(id: id)?.role else { XCTFail(id); continue }
      XCTAssertEqual(binding.wrappedValue, value, id)
    }
  }

  func test_everyCycleRow_emitsItsOwnChange() {
    let expected: [(String, AnyHashable, ConfigWiiChange)] = [
      ("aspect-ratio", AnyHashable(true), .widescreen(true)),
      ("aspect-ratio", AnyHashable(false), .widescreen(false)),
      ("language", AnyHashable(6), .language(6)),
      ("sound-mode", AnyHashable(2), .soundMode(2)),
      ("sensor-bar-position", AnyHashable(1), .sensorBarPosition(1)),
    ]
    let m = model()
    for (id, value, change) in expected {
      guard case .cycle(_, let selection)? = m.item(id: id)?.role else { XCTFail("\(id) is not a cycle"); continue }
      changes = []
      selection.wrappedValue = value
      XCTAssertEqual(changes, [change], id)
    }
  }

  func test_steppers_haveTheirRanges_andEmitTheirOwnChange() {
    let expected: [(String, ClosedRange<Double>, Double, ConfigWiiChange)] = [
      ("sensor-bar-sensitivity", 1 ... 5, 4, .sensorBarSensitivity(4)),
      ("speaker-volume", 0 ... 7, 6, .speakerVolume(6)),
    ]
    let m = model()
    for (id, range, value, change) in expected {
      guard case .stepper(let stepper)? = m.item(id: id)?.role else { XCTFail("\(id) is not a stepper"); continue }
      XCTAssertEqual(stepper.range, range, id)
      XCTAssertEqual(stepper.step, 1, id)
      changes = []
      stepper.value.wrappedValue = value
      XCTAssertEqual(changes, [change], id)
    }
  }

  func test_steppers_showTheirValueAsAWholeNumber() {
    let m = model(state { $0.sensorBarSensitivity = 3; $0.speakerVolume = 7 })
    XCTAssertEqual(m.item(id: "sensor-bar-sensitivity")?.currentValueTitle, "3")
    XCTAssertEqual(m.item(id: "speaker-volume")?.currentValueTitle, "7")
  }

  func test_language_listsTheTenWiiLanguages_inIndexOrder() {
    guard case .cycle(let options, _)? = model().item(id: "language")?.role else { return XCTFail("not a cycle") }
    XCTAssertEqual(options.map(\.0), ["Japanese", "English", "German", "French", "Spanish", "Italian", "Dutch", "Simplified Chinese", "Traditional Chinese", "Korean"])
    XCTAssertEqual(options.map { $0.1.base as? Int }, Array(0 ... 9))
  }

  func test_cycleRows_showTheirStoredLabel() {
    let cases: [(String, (inout ConfigWiiState) -> Void, String)] = [
      ("aspect-ratio", { $0.widescreen = false }, "4:3"), ("aspect-ratio", { $0.widescreen = true }, "16:9"),
      ("language", { $0.language = 0 }, "Japanese"), ("language", { $0.language = 9 }, "Korean"),
      ("sound-mode", { $0.soundMode = 0 }, "Mono"), ("sound-mode", { $0.soundMode = 1 }, "Stereo"), ("sound-mode", { $0.soundMode = 2 }, "Surround"),
      ("sensor-bar-position", { $0.sensorBarPosition = 0 }, "Bottom"), ("sensor-bar-position", { $0.sensorBarPosition = 1 }, "Top"),
    ]
    for (id, edit, title) in cases {
      XCTAssertEqual(model(state(edit)).item(id: id)?.currentValueTitle, title, "\(id) \(title)")
    }
  }

  func test_aStoredValueMatchingNoOptionIsInsertedRatherThanShownAsADash() {
    let cases: [(String, (inout ConfigWiiState) -> Void, Int, Int)] = [
      ("language", { $0.language = 12 }, 12, 11),
      ("sound-mode", { $0.soundMode = 5 }, 5, 4),
      ("sensor-bar-position", { $0.sensorBarPosition = 3 }, 3, 3),
    ]
    for (id, edit, value, count) in cases {
      guard case .cycle(let options, _)? = model(state(edit)).item(id: id)?.role else { XCTFail(id); continue }
      XCTAssertEqual(options.count, count, id)
      XCTAssertEqual(options.last?.1.base as? Int, value, id)
      XCTAssertEqual(options.last?.0, "Error", id)
    }
  }

  func test_defaults_matchTheOldViewsState() {
    let s = ConfigWiiState()
    XCTAssertEqual(s.language, 1)
    XCTAssertEqual(s.soundMode, 1)
    XCTAssertEqual(s.sensorBarPosition, 0)
    XCTAssertEqual(s.sensorBarSensitivity, 2)
    XCTAssertEqual(s.speakerVolume, 4)
    XCTAssertTrue(s.wiimoteRumble)
    XCTAssertEqual([s.pal60, s.widescreen, s.screensaver, s.touchpadIRFollowWithoutClick, s.skylanderPortal, s.keyboard, s.wiilink, s.sdFolderSync], Array(repeating: false, count: 8))
  }
}
