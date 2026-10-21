// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import XCTest
@testable import iCube

final class ClassicSlotSaveAdmissionTests: XCTestCase {
  private final class Fixture: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let lock = NSLock()
    var session = QuickSaveSurfaceSession(gameID: "GALE01", identifier: 7)
    var destination: URL?
    var writes: [Int] = []
    var results: [Int: Bool] = [:]
    init() throws {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      destination = root.appendingPathComponent("GALE01.s04")
    }
    func consent(overwrite: Bool = false) -> ClassicSlotSaveConsent {
      ClassicSlotSaveConsent(request: QuickSaveSlotSaveRequest(session: session, slot: 4, path: destination!), allowsOverwrite: overwrite)
    }
    func currentSession() -> QuickSaveSurfaceSession { lock.lock(); defer { lock.unlock() }; return session }
    func currentDestination(_ slot: Int) -> URL? { lock.lock(); defer { lock.unlock() }; return destination }
    func record(_ id: Int, success: Bool) { lock.lock(); defer { lock.unlock() }; results[id] = success }
    func write(_ id: Int) -> Int? {
      lock.lock(); writes.append(id); lock.unlock()
      do {
        let path = root.appendingPathComponent("GALE01.s04")
        try Data([UInt8(id)]).write(to: path)
        try Data([UInt8(id), 99]).write(to: path.appendingPathExtension("json"))
        return id
      } catch { return nil }
    }
  }

  func testQueuedUnconfirmedBDoesNotReplacePendingAAfterItsCommit() throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let queue = ClassicSlotSaveExecutor(queue: DispatchQueue(label: "test.classic-consent"))
    let started = expectation(description: "A admitted, payload not committed")
    let completed = expectation(description: "Both queued requests completed")
    completed.expectedFulfillmentCount = 2
    let releaseA = DispatchSemaphore(value: 0)
    let consent = fixture.consent()
    queue.enqueue(consent, currentSession: { fixture.currentSession() }, destination: { fixture.currentDestination($0) },
      write: { _ in started.fulfill(); releaseA.wait(); return fixture.write(1) },
      completion: { fixture.record(1, success: $0 != nil); completed.fulfill() })
    wait(for: [started], timeout: 2)
    XCTAssertFalse(FileManager.default.fileExists(atPath: consent.request.path.path))
    // B is actually appended to the same serialized executor while A's destination is still empty.
    queue.enqueue(consent, currentSession: { fixture.currentSession() }, destination: { fixture.currentDestination($0) },
      write: { _ in fixture.write(2) },
      completion: { fixture.record(2, success: $0 != nil); completed.fulfill() })
    releaseA.signal()
    wait(for: [completed], timeout: 2)
    XCTAssertEqual(fixture.writes, [1])
    XCTAssertEqual(fixture.results, [1: true, 2: false])
    XCTAssertEqual(try Data(contentsOf: consent.request.path), Data([1]))
    XCTAssertEqual(try Data(contentsOf: consent.request.path.appendingPathExtension("json")), Data([1, 99]))
  }

  func testExplicitConsentPermitsSameCapturedDestinationReplacement() throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = fixture.write(1)
    let consent = fixture.consent(overwrite: true)
    let completed = expectation(description: "Approved replacement completed")
    ClassicSlotSaveExecutor(queue: DispatchQueue(label: "test.explicit-consent")).enqueue(consent,
      currentSession: { fixture.currentSession() }, destination: { fixture.currentDestination($0) },
      write: { captured in
        XCTAssertEqual(captured, consent)
        return fixture.write(2)
      }, completion: { fixture.record(2, success: $0 != nil); completed.fulfill() })
    wait(for: [completed], timeout: 2)
    XCTAssertEqual(fixture.writes, [1, 2])
    XCTAssertEqual(fixture.results[2], true)
    XCTAssertEqual(try Data(contentsOf: consent.request.path), Data([2]))
  }

  func testQueuedConsentRejectsDestinationAndSessionDriftBeforeWriter() throws {
    for changedSession in [false, true] {
      let fixture = try Fixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let consent = fixture.consent(overwrite: true)
      let completed = expectation(description: "Drift rejected")
      let dispatchQueue = DispatchQueue(label: "test.consent-drift")
      dispatchQueue.suspend()
      ClassicSlotSaveExecutor(queue: dispatchQueue).enqueue(consent,
        currentSession: { fixture.currentSession() }, destination: { fixture.currentDestination($0) },
        write: { _ in fixture.write(2) }, completion: { fixture.record(2, success: $0 != nil); completed.fulfill() })
      // Drift occurs after enqueueing but before serialized admission/writer execution.
      if changedSession { fixture.session = QuickSaveSurfaceSession(gameID: "GALE01", identifier: 8) }
      else { fixture.destination = fixture.root.appendingPathComponent("modded.s04") }
      dispatchQueue.resume()
      wait(for: [completed], timeout: 2)
      XCTAssertTrue(fixture.writes.isEmpty)
      XCTAssertEqual(fixture.results[2], false)
    }
  }

  func testUnreadableOccupancyLookupFailsClosedEvenWithOverwriteApproval() throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let parentFile = fixture.root.appendingPathComponent("parent-file")
    try Data([1]).write(to: parentFile)
    fixture.destination = parentFile.appendingPathComponent("GALE01.s04") // ENOTDIR, not an absent slot.
    let completed = expectation(description: "Unknown occupancy rejected")
    ClassicSlotSaveExecutor(queue: DispatchQueue(label: "test.unknown-occupancy")).enqueue(fixture.consent(overwrite: true),
      currentSession: { fixture.currentSession() }, destination: { fixture.currentDestination($0) },
      write: { _ in fixture.write(2) }, completion: { fixture.record(2, success: $0 != nil); completed.fulfill() })
    wait(for: [completed], timeout: 2)
    XCTAssertTrue(fixture.writes.isEmpty)
    XCTAssertEqual(fixture.results[2], false)
  }
}
