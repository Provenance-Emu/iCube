// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

@MainActor
final class QuickSaveSurfaceActionTests: XCTestCase {
  private let session = QuickSaveSurfaceSession(gameID: "GALE01", identifier: 7)
  private let path = URL(fileURLWithPath: "/states/GALE01.s04")

  private func state(compatible: Bool = true) -> SaveStateInfo {
    SaveStateInfo(gameID: "GALE01", displayName: "Slot 4", slot: 4, createdAt: nil,
      modifiedAt: nil, sizeBytes: nil, versionHash: nil, isCompatible: compatible,
      path: path, thumbnailURL: nil, isAuto: false)
  }

  func testSuspendedInitialScanCannotSaveThenOccupiedSlotRequiresExplicitConfirmation() async {
    let scan = QuickSavePickerScan()
    var continuation: CheckedContinuation<[SaveStateInfo], Never>?
    let task = Task { await scan.reload { await withCheckedContinuation { continuation = $0 } } }
    while continuation == nil { await Task.yield() }
    var writes = 0
    let pending = scan.prepareSave(slot: 4, session: session, destination: path, occupancy: .occupied)
    XCTAssertEqual(pending, .unavailable)
    XCTAssertFalse(scan.hasCompletedScan)
    continuation?.resume(returning: [state()])
    await task.value
    guard case .confirm(let request) = scan.prepareSave(slot: 4, session: session, destination: path, occupancy: .occupied) else {
      return XCTFail("Occupied slot must require confirmation")
    }
    let unconfirmed = await scan.save(request, confirmed: false, isCurrent: { $0 == self.session }, destination: { _ in self.path }, occupancy: { _ in .occupied }) { _ in
      writes += 1; return true
    }
    XCTAssertNil(unconfirmed)
    XCTAssertEqual(writes, 0)
    let confirmed = await scan.save(request, confirmed: true, isCurrent: { $0 == self.session }, destination: { _ in self.path }, occupancy: { _ in .occupied }) { saved in
      XCTAssertEqual(saved.slot, 4)
      XCTAssertEqual(saved.path, self.path)
      writes += 1; return true
    }
    XCTAssertEqual(confirmed, true)
    XCTAssertEqual(writes, 1)
  }

  func testEmptyOrFailedProviderScanDoesNotOverrideAuthoritativeOccupiedDestination() async {
    let scan = QuickSavePickerScan()
    await scan.reload { [] } // The existing provider also returns [] for a failed directory scan.
    guard case .confirm = scan.prepareSave(slot: 4, session: session, destination: path, occupancy: .occupied) else {
      return XCTFail("An empty provider result cannot authorize replacement")
    }
    XCTAssertEqual(scan.prepareSave(slot: 4, session: session, destination: path, occupancy: .unknown), .unavailable)
    XCTAssertEqual(scan.prepareSave(slot: 4, session: session, destination: nil, occupancy: .empty), .unavailable)
  }

  func testDestinationThatBecomesOccupiedAfterScanCannotSaveWithoutConfirmation() async {
    let scan = QuickSavePickerScan()
    await scan.reload { [] }
    guard case .save(let request) = scan.prepareSave(slot: 4, session: session, destination: path, occupancy: .empty) else {
      return XCTFail("Completed scan and empty destination should allow save")
    }
    var writes = 0
    let result = await scan.save(request, confirmed: false, isCurrent: { _ in true }, destination: { _ in self.path }, occupancy: { _ in .occupied }) { _ in writes += 1; return true }
    XCTAssertNil(result)
    XCTAssertEqual(writes, 0)
  }

  func testConfirmationCannotMoveToDifferentDestinationOrSession() async {
    let scan = QuickSavePickerScan()
    await scan.reload { [self.state()] }
    guard case .confirm(let request) = scan.prepareSave(slot: 4, session: session, destination: path, occupancy: .occupied) else { return XCTFail("Missing confirmation") }
    var writes = 0
    let changedPath = await scan.save(request, confirmed: true, isCurrent: { _ in true }, destination: { _ in URL(fileURLWithPath: "/modded/GALE01.s04") }, occupancy: { _ in .occupied }) { _ in writes += 1; return true }
    let changedSession = await scan.save(request, confirmed: true, isCurrent: { _ in false }, destination: { _ in self.path }, occupancy: { _ in .occupied }) { _ in writes += 1; return true }
    XCTAssertNil(changedPath)
    XCTAssertNil(changedSession)
    XCTAssertEqual(writes, 0)
  }

  func testCancelledScanDoesNotEstablishEmptyOccupancy() async {
    let scan = QuickSavePickerScan()
    let task = Task { await scan.reload { withUnsafeCurrentTask { $0?.cancel() }; return [] } }
    await task.value
    XCTAssertFalse(scan.hasCompletedScan)
    XCTAssertEqual(scan.prepareSave(slot: 4, session: session, destination: path, occupancy: .empty), .unavailable)
  }

  func testFilesystemOccupancyDistinguishesMissingPayloadExistingPayloadAndUnreadablePath() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = root.appendingPathComponent("GALE01.s04")
    XCTAssertEqual(QuickSaveDestinationOccupancy.read(payload), .empty)
    try Data([1]).write(to: payload)
    XCTAssertEqual(QuickSaveDestinationOccupancy.read(payload), .occupied)
    // ENOTDIR must not be interpreted as an empty slot.
    XCTAssertEqual(QuickSaveDestinationOccupancy.read(payload.appendingPathComponent("child")), .unknown)
  }

  func testPrimaryPaneLoadRejectsEmptyIncompatibleAndStaleSessionBeforeCallback() async {
    var loads = 0
    for candidate in [nil, state(compatible: false), state()] {
      let result = await QuickSaveSurfaceActions.load(candidate, session: session, isCurrent: { _ in candidate?.isCompatible != true }) { _ in loads += 1; return QuickSaveActions.Outcome.loadRequested(self.path) }
      XCTAssertNil(result)
    }
    XCTAssertEqual(loads, 0)
  }

  func testPrimaryPaneLoadReturnsAwaitedFailureAndSuppressesStaleCompletion() async {
    var current = true
    let failed = await QuickSaveSurfaceActions.load(state(), session: session, isCurrent: { _ in current }) { _ in QuickSaveActions.Outcome.unavailable }
    XCTAssertEqual(failed, .unavailable)
    XCTAssertFalse(failed!.isSuccess)
    XCTAssertEqual(failed!.message, "Game isn't ready to load yet")
    let stale = await QuickSaveSurfaceActions.load(state(), session: session, isCurrent: { _ in current }) { _ in current = false; return QuickSaveActions.Outcome.loadRequested(self.path) }
    XCTAssertNil(stale)
  }

  func testPrimaryPaneLoadPreservesCapturedFileAndCurrentOutcome() async {
    let result = await QuickSaveSurfaceActions.load(state(), session: session, isCurrent: { $0 == self.session }) { selected in
      XCTAssertEqual(selected.path, self.path)
      return QuickSaveActions.Outcome.loadRequested(self.path)
    }
    XCTAssertEqual(result, .loadRequested(path))
  }
}
