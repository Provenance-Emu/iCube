// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// The tvOS Save States pane's pure parts: `-ICubePauseFocus` parsing (Scripts/tvos_screens.sh captures a
/// focused slot with it) and which state each slot card shows.
final class TVSaveSlotsPaneTests: XCTestCase {
  func testDebugFocusSlotsUseTheUINumbering() {
    XCTAssertEqual(TVSaveSlotsPane.debugFocus("slot-1"), .slot(1))
    XCTAssertEqual(TVSaveSlotsPane.debugFocus("slot-10"), .slot(10))
    XCTAssertEqual(TVSaveSlotsPane.debugFocus("view-all"), .viewAll)
  }

  func testDebugFocusUnknownOrOutOfRangeIsNil() {
    XCTAssertNil(TVSaveSlotsPane.debugFocus(nil))
    XCTAssertNil(TVSaveSlotsPane.debugFocus("slot-0"))
    XCTAssertNil(TVSaveSlotsPane.debugFocus("slot-11"))
    XCTAssertNil(TVSaveSlotsPane.debugFocus("slot-x"))
    XCTAssertNil(TVSaveSlotsPane.debugFocus("back"))
  }

  func testLatestBySlotKeepsTheNewestStatePerSlot() {
    let older = state(slot: 2, modified: 100)
    let newer = state(slot: 2, modified: 200)
    let other = state(slot: 5, modified: 50)
    let bySlot = TVSaveSlotsPane.latestBySlot([older, other, newer])
    XCTAssertEqual(bySlot[2]?.id, newer.id)
    XCTAssertEqual(bySlot[5]?.id, other.id)
    XCTAssertEqual(bySlot.count, 2)
  }

  func testLatestBySlotSkipsTheAutoStateAndSlotlessStates() {
    let auto = state(slot: 1, modified: 300, isAuto: true)
    let slotless = state(slot: nil, modified: 300)
    XCTAssertTrue(TVSaveSlotsPane.latestBySlot([auto, slotless]).isEmpty)
  }

  func testLatestBySlotFallsBackToCreatedAt() {
    let created = state(slot: 3, modified: nil, created: 500)
    let modified = state(slot: 3, modified: 400)
    XCTAssertEqual(TVSaveSlotsPane.latestBySlot([modified, created])[3]?.id, created.id)
  }

  @MainActor
  func testPrimaryPaneLoadItemDisablesEmptyIncompatibleAndBusyStatesWithoutActivation() {
    let valid = state(slot: 4, modified: 10)
    let incompatible = SaveStateInfo(gameID: valid.gameID, displayName: valid.displayName, slot: valid.slot,
      createdAt: valid.createdAt, modifiedAt: valid.modifiedAt, sizeBytes: valid.sizeBytes,
      versionHash: valid.versionHash, isCompatible: false, path: valid.path,
      thumbnailURL: valid.thumbnailURL, isAuto: valid.isAuto)
    var loads = 0
    for (candidate, busy) in [(nil, false), (incompatible, false), (valid, true)] as [(SaveStateInfo?, Bool)] {
      let item = TVSaveSlotsPane.loadItem(state: candidate, busy: busy) { _ in loads += 1 }
      XCTAssertFalse(item.isEnabled)
      item.activateInPlace()
    }
    XCTAssertEqual(loads, 0)
  }

  @MainActor
  func testPrimaryPaneLoadItemActivatesOnlyItsCompatibleSelectedFile() {
    let selected = state(slot: 4, modified: 10)
    var loadedPath: URL?
    let item = TVSaveSlotsPane.loadItem(state: selected, busy: false) { loadedPath = $0.path }
    XCTAssertTrue(item.isEnabled)
    item.activateInPlace()
    XCTAssertEqual(loadedPath, selected.path)
  }

  @MainActor
  func testManageSaveHereCannotReplaceDestinationOccupiedAfterPanelOpened() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("GALE01.s04")
    let session = QuickSaveSurfaceSession(gameID: "GALE01", identifier: 7)
    let scan = QuickSavePickerScan()
    await scan.reload { [] }
    guard case .save(let request) = scan.prepareSave(slot: 4, session: session, destination: path,
                                                    occupancy: QuickSaveDestinationOccupancy.read(path)) else {
      return XCTFail("The managed request must begin as an empty Save Here")
    }
    var writeTask: Task<Bool?, Never>?
    var writes = 0
    let item = TVSaveSlotsPane.saveItem(request: request, requiresOverwrite: false, busy: false) { captured, confirmed in
      writeTask = Task {
        await scan.save(captured, confirmed: confirmed, isCurrent: { $0 == session },
          destination: { _ in path }, occupancy: QuickSaveDestinationOccupancy.read) { _ in
          writes += 1
          return true
        }
      }
    }
    // A sync/queued save lands after this actual manage item was built, before its activation.
    try Data([9, 8, 7]).write(to: path)
    item.activateInPlace()
    let task = try XCTUnwrap(writeTask)
    let result = await task.value
    XCTAssertNil(result)
    XCTAssertEqual(writes, 0)
    XCTAssertEqual(try Data(contentsOf: path), Data([9, 8, 7]))
  }

  @MainActor
  func testManageOverwritePreservesExplicitApprovalAndCapturedRequest() async throws {
    let path = URL(fileURLWithPath: "/states/GALE01.s04")
    let session = QuickSaveSurfaceSession(gameID: "GALE01", identifier: 7)
    let scan = QuickSavePickerScan()
    await scan.reload { [] }
    guard case .confirm(let request) = scan.prepareSave(slot: 4, session: session, destination: path,
                                                       occupancy: .occupied) else {
      return XCTFail("An occupied slot must begin with explicit Overwrite")
    }
    var writeTask: Task<Bool?, Never>?
    var writes = 0
    var managedRequiresOverwrite = true
    let item = TVSaveSlotsPane.saveItem(request: request, requiresOverwrite: managedRequiresOverwrite, busy: false) { captured, confirmed in
      // The view closes the manage panel and resets its mutable flag before the async write.
      managedRequiresOverwrite = false
      writeTask = Task {
        await scan.save(captured, confirmed: confirmed, isCurrent: { $0 == session },
          destination: { _ in path }, occupancy: { _ in .occupied }) { written in
          XCTAssertEqual(written.session, session)
          XCTAssertEqual(written.slot, 4)
          XCTAssertEqual(written.path, path)
          writes += 1
          return true
        }
      }
    }
    item.activateInPlace()
    let task = try XCTUnwrap(writeTask)
    let result = await task.value
    XCTAssertEqual(result, true)
    XCTAssertEqual(writes, 1)
    XCTAssertFalse(managedRequiresOverwrite)
  }

  private func state(slot: Int?, modified: TimeInterval?, created: TimeInterval? = nil, isAuto: Bool = false) -> SaveStateInfo {
    SaveStateInfo(gameID: "GALE01", displayName: "State", slot: slot,
                  createdAt: created.map(Date.init(timeIntervalSince1970:)),
                  modifiedAt: modified.map(Date.init(timeIntervalSince1970:)),
                  sizeBytes: nil, versionHash: nil, isCompatible: true,
                  path: URL(fileURLWithPath: "/tmp/GALE01.s0\(slot ?? 0)"), thumbnailURL: nil, isAuto: isAuto)
  }
}
