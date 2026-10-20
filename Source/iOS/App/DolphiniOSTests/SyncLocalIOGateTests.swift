// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import iCube
import Foundation
import XCTest

final class SyncLocalIOGateTests: XCTestCase {
  func testBootClosesAdmissionUntilEmulationEnds() {
    let gate = SyncLocalIOGate()
    gate.beginEmulation()
    XCTAssertTrue(gate.isEmulating)
    XCTAssertFalse(gate.beginLocalIO())
    gate.endEmulation()
    XCTAssertTrue(gate.beginLocalIO())
    gate.endLocalIO()
  }

  func testBootWaitsForExistingLocalIOButDoesNotHoldItsConditionLock() {
    let gate = SyncLocalIOGate()
    XCTAssertTrue(gate.beginLocalIO())
    gate.beginEmulation()
    let waiting = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      waiting.signal()
      gate.waitForLocalIO()
      finished.signal()
    }
    XCTAssertEqual(waiting.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(finished.wait(timeout: .now() + 0.05), .timedOut)
    XCTAssertFalse(gate.beginLocalIO())
    gate.endLocalIO()
    XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
  }

  func testOldCoreDrainCannotOpenANewPendingBoot() {
    let gate = SyncLocalIOGate()
    let old = gate.beginEmulation()
    let current = gate.beginEmulation()
    XCTAssertFalse(gate.finishCoreDrain(generation: old))
    XCTAssertFalse(gate.beginLocalIO())
    XCTAssertTrue(gate.finishCoreDrain(generation: current))
    XCTAssertTrue(gate.beginLocalIO())
    gate.endLocalIO()
  }

  func testSupersededWorkerCannotReopenAdmissionAfterNewBootDrains() {
    let gate = SyncLocalIOGate()
    let old = gate.beginEmulation()
    let current = gate.beginEmulation()
    XCTAssertTrue(gate.finishCoreDrain(generation: current))
    XCTAssertFalse(gate.ensureEmulation(generation: old))
    XCTAssertFalse(gate.isCurrentEmulation(old))
    XCTAssertFalse(gate.finishCoreDrain(generation: old))
    XCTAssertTrue(gate.beginLocalIO())
    gate.endLocalIO()
  }

  func testBootBeforeSyncStartsNeedsNoCoordinatorOrLease() {
    let gate = SyncLocalIOGate()
    gate.beginEmulation()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { gate.waitForLocalIO(); done.signal() }
    XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
    gate.endEmulation()
    XCTAssertTrue(gate.beginLocalIO())
    gate.endLocalIO()
  }
}
