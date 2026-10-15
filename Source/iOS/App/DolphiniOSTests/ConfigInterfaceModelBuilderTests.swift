// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class ConfigInterfaceModelBuilderTests: XCTestCase {
  private var changes: [ConfigInterfaceChange] = []
  private func model(_ state: ConfigInterfaceState = ConfigInterfaceState()) -> MenuModel {
    ConfigInterfaceModelBuilder.make(state: state) { self.changes.append($0) }
  }

  func test_rowOrder_andSections() {
    #if os(iOS)
    let recordingIDs = ["recording-watermark", "recording-camera"]
    #else
    let recordingIDs = ["recording-watermark"]
    #endif
    XCTAssertEqual(model().allItems.map(\.id),
                   ["names-db", "covers", "background-style", "show-subtitles", "show-patched-separately", "confirm-on-stop", "panic-handlers", "osd-messages"] + recordingIDs)
    XCTAssertEqual(model().sections.map(\.header), ["Game List", "Library UI", "General", "Recording"])
    XCTAssertEqual(model().sections.map(\.items.count), [2, 3, 3, recordingIDs.count])
  }

  func test_everyRow_hasADescription() {
    for item in model().allItems { XCTAssertFalse((item.description ?? "").isEmpty, item.id) }
  }

  func test_everyToggleRow_emitsItsOwnChange() {
    let expected: [(String, (Bool) -> ConfigInterfaceChange)] = [
      ("names-db", { .useNamesDB($0) }), ("covers", { .useCovers($0) }), ("show-subtitles", { .showSubtitles($0) }),
      ("show-patched-separately", { .showPatchedSeparately($0) }),
      ("confirm-on-stop", { .confirmOnStop($0) }), ("panic-handlers", { .usePanicHandlers($0) }), ("osd-messages", { .osdMessages($0) }),
      ("recording-watermark", { .recordingWatermark($0) }),
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

  func test_backgroundStyleCycle_offersEveryStyle_andEmits() {
    guard case .cycle(let options, let selection)? = model().item(id: "background-style")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map { $0.0 }, LibraryBackgroundStyle.allCases.map(\.label))
    XCTAssertEqual(options.map { $0.1 }, LibraryBackgroundStyle.allCases.map { AnyHashable($0) })
    selection.wrappedValue = AnyHashable(LibraryBackgroundStyle.animated)
    XCTAssertEqual(changes, [.backgroundStyle(.animated)])
    for style in LibraryBackgroundStyle.allCases {
      var s = ConfigInterfaceState()
      s.backgroundStyle = style
      XCTAssertEqual(model(s).item(id: "background-style")?.currentValueTitle, style.label)
    }
  }

  func test_toggleRows_showTheStateValue() {
    var s = ConfigInterfaceState()
    s.useNamesDB = true; s.useCovers = true; s.showSubtitles = false; s.showPatchedSeparately = false
    s.confirmOnStop = false; s.usePanicHandlers = false; s.osdMessages = false
    let m = model(s)
    let expected: [(String, Bool)] = [
      ("names-db", true), ("covers", true), ("show-subtitles", false), ("show-patched-separately", false),
      ("confirm-on-stop", false), ("panic-handlers", false), ("osd-messages", false),
    ]
    for (id, value) in expected {
      guard case .toggle(let binding)? = m.item(id: id)?.role else { XCTFail("\(id) is not a toggle"); continue }
      XCTAssertEqual(binding.wrappedValue, value, id)
    }
  }

  func test_unsetSubtitlesKey_meansOn_storedWins() {
    XCTAssertTrue(ConfigInterfaceState.storedShowSubtitles(nil))
    XCTAssertTrue(ConfigInterfaceState.storedShowSubtitles(true))
    XCTAssertFalse(ConfigInterfaceState.storedShowSubtitles(false))
  }

  func test_unsetPatchedSeparatelyKey_meansOn_storedWins() {
    XCTAssertTrue(ConfigInterfaceState().showPatchedSeparately)
    XCTAssertTrue(ConfigInterfaceState.storedShowPatchedSeparately(nil))
    XCTAssertTrue(ConfigInterfaceState.storedShowPatchedSeparately(true))
    XCTAssertFalse(ConfigInterfaceState.storedShowPatchedSeparately(false))
    XCTAssertEqual(ConfigInterfaceDefaultsKey.showPatchedSeparately, "library_show_patched_separately")
  }

  func test_recordingDefaults_watermarkOn_cameraOff() {
    let s = ConfigInterfaceState()
    XCTAssertTrue(s.recordingWatermark); XCTAssertFalse(s.recordingCamera)
    XCTAssertTrue(ConfigInterfaceState.storedRecordingWatermark(nil))
    XCTAssertFalse(ConfigInterfaceState.storedRecordingWatermark(false))
    XCTAssertEqual(ConfigInterfaceDefaultsKey.recordingWatermark, "recording_watermark")
    XCTAssertEqual(ConfigInterfaceDefaultsKey.recordingCamera, "recording_camera_overlay")
  }

  func test_defaults_matchTheOldView() {
    let s = ConfigInterfaceState()
    XCTAssertTrue(s.confirmOnStop); XCTAssertTrue(s.usePanicHandlers); XCTAssertTrue(s.osdMessages); XCTAssertTrue(s.showSubtitles)
    XCTAssertFalse(s.useNamesDB); XCTAssertFalse(s.useCovers)
    XCTAssertEqual(s.backgroundStyle, .gradient)
  }

  func test_defaultsKeys_areTheOnesTVLibraryViewReads() {
    XCTAssertEqual(ConfigInterfaceDefaultsKey.backgroundStyle, "library_background_style")
    XCTAssertEqual(ConfigInterfaceDefaultsKey.showSubtitles, "library_show_subtitles")
  }
}
