// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class QuickSavePickerModelTests: XCTestCase {
  private func state(_ name: String, slot: Int? = nil, time: TimeInterval = 10,
                     compatible: Bool = true, automatic: Bool = false, history: Bool = false) -> SaveStateInfo {
    SaveStateInfo(gameID: "GALE01", displayName: name, slot: slot, createdAt: nil,
                  modifiedAt: Date(timeIntervalSince1970: time), sizeBytes: nil,
                  versionHash: nil, isCompatible: compatible,
                  path: URL(fileURLWithPath: "/states/\(name)"), thumbnailURL: nil,
                  isAuto: automatic, isQuickSave: history)
  }

  func testSelectionOnlySelectsAndSurvivesProviderUUIDChanges() {
    let first = state("GALE01.s01", slot: 1)
    let reloaded = state("GALE01.s01", slot: 1)
    var selection = QuickSavePickerSelection()
    selection.select(first)
    XCTAssertNotEqual(first.id, reloaded.id)
    selection.reconcile(states: [reloaded])
    XCTAssertEqual(selection.historyPath, reloaded.path)
  }

  func testMissingSelectionFallsBackToNewestManualBeforeAutomatic() {
    var selection = QuickSavePickerSelection(historyPath: URL(fileURLWithPath: "/vanished"))
    let manual = state("manual", time: 10)
    selection.reconcile(states: [state("auto", time: 100, automatic: true), manual])
    XCTAssertEqual(selection.historyPath, manual.path)
    selection.reconcile(states: [])
    XCTAssertNil(selection.historyPath)
  }

  func testEmptyAndIncompatibleStatesCannotLoad() {
    XCTAssertFalse(QuickSavePickerModel.canLoad(nil, busy: false))
    XCTAssertFalse(QuickSavePickerModel.canLoad(state("old", compatible: false), busy: false))
    XCTAssertFalse(QuickSavePickerModel.canLoad(state("valid"), busy: true))
    XCTAssertTrue(QuickSavePickerModel.canLoad(state("valid"), busy: false))
  }

  func testOnlyOccupiedClassicSlotNeedsReplacementConfirmation() {
    let occupied = state("GALE01.s04", slot: 4)
    XCTAssertTrue(QuickSavePickerModel.needsOverwriteConfirmation(slot: 4, states: [occupied]))
    XCTAssertFalse(QuickSavePickerModel.needsOverwriteConfirmation(slot: 1, states: [occupied]))
    XCTAssertEqual(QuickSavePickerModel.slots, Array(1...10))
  }

  func testHistoryLatestBadgeMatchesQuickLoadIncludingLegacySlot() {
    let legacy = state("GALE01.s02", slot: 2, time: 40)
    let states = [state("quick", time: 30, history: true), state("auto", time: 100, automatic: true), legacy]
    XCTAssertEqual(QuickSavePickerModel.manualStates(states).first?.path, legacy.path)
    XCTAssertEqual(QuickSaveHistoryPolicy.loadTarget(states: states, modded: false), .manual(legacy.path))
  }

  func testModdedPickerRemovesAutomaticAndHistoryStates() {
    let classic = state("GALE01.s01", slot: 1)
    let states = [classic, state("quick", history: true), state("auto", automatic: true)]
    XCTAssertEqual(QuickSavePickerModel.visibleStates(states, modded: true).map(\.path), [classic.path])
    XCTAssertEqual(QuickSavePickerModel.visibleStates(states, modded: false).count, 3)
  }
}
