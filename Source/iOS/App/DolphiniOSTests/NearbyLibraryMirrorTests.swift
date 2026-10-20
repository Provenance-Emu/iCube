// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import XCTest
@testable import iCube

@MainActor
final class NearbyLibraryMirrorTests: XCTestCase {
  @MainActor
  private final class Boundary {
    var trusted: Set<String> = ["paired"]
    var discovered: Set<String> = ["paired", "stranger"]
    var active = true
    var emulating = false
    var entries = [NearbyLibraryMirror.Entry(id: "disc1"), .init(id: "disc2")]
    var present = Set<String>()
    var requestedPeers: [String] = []
    var copies: [String] = []
    var cancels = 0
    var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
    var cancelledTimers = Set<Int>()
    var holdCatalog = false
    var pendingCatalog: CheckedContinuation<[NearbyLibraryMirror.Entry], Error>?
    var holdCopy = false
    var failCopy = false
    var pendingCopy: CheckedContinuation<Void, Error>?

    func make() -> NearbyLibraryMirror {
      NearbyLibraryMirror(
        catalog: { peer in
          self.requestedPeers.append(peer)
          if self.holdCatalog {
            return try await withCheckedThrowingContinuation { self.pendingCatalog = $0 }
          }
          return self.entries
        },
        copy: { _, entry in
          self.copies.append(entry.id)
          if self.failCopy { throw NSError(domain: "copy", code: 1) }
          if self.holdCopy {
            try await withCheckedThrowingContinuation { self.pendingCopy = $0 }
          }
          self.present.insert(entry.id)
        },
        cancel: { self.cancels += 1 },
        isTrusted: { self.trusted.contains($0) },
        isDiscovered: { self.discovered.contains($0) },
        isActive: { self.active },
        isEmulating: { self.emulating },
        isPresent: { _, entry in self.present.contains(entry.id) },
        schedule: { delay, callback in
          let index = self.scheduled.count
          self.scheduled.append((delay, callback))
          return { self.cancelledTimers.insert(index) }
        }
      )
    }

    func releaseCopy() {
      let continuation = pendingCopy
      pendingCopy = nil
      continuation?.resume()
    }
  }

  private func settle(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<1000 {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("Scheduler did not reach the expected state")
  }

  func testOptInRequiresTrustAndNeverPairsUnknownPeers() async {
    let b = Boundary(); let mirror = b.make()
    mirror.environmentChanged()
    mirror.setEnabled(true, for: "stranger")
    await Task.yield()
    XCTAssertTrue(mirror.enabledPeerIDs.isEmpty)
    XCTAssertTrue(b.requestedPeers.isEmpty)
    XCTAssertTrue(b.copies.isEmpty)
    XCTAssertEqual(mirror.state, .disabled)
  }

  func testInitialAndSubsequentPassesDeduplicateAndCheckActualLocalPresence() async {
    let b = Boundary(); b.entries.append(.init(id: "disc1"))
    let mirror = b.make(); mirror.setEnabled(true, for: "paired")
    await settle { mirror.state == .upToDate }
    XCTAssertEqual(b.copies, ["disc1", "disc2"])
    XCTAssertEqual(b.scheduled.last?.0, 60)
    b.entries.append(.init(id: "revision2"))
    b.present.remove("disc1") // tvOS may purge a previously imported ROM.
    b.scheduled.last?.1()
    await settle { b.copies.count == 4 && mirror.state == .upToDate }
    XCTAssertEqual(b.copies, ["disc1", "disc2", "disc1", "revision2"])
    b.entries = [] // An empty/outdated remote catalog never deletes a local copy.
    b.scheduled.last?.1()
    await settle { b.requestedPeers.count == 3 && mirror.state == .upToDate }
    XCTAssertEqual(b.present, ["disc1", "disc2", "revision2"])
    mirror.stop()
  }

  func testRepeatedDiscoveryEventsDoNotStartConcurrentCopies() async {
    let b = Boundary(); b.holdCopy = true
    let mirror = b.make(); mirror.setEnabled(true, for: "paired")
    await settle { b.pendingCopy != nil }
    for _ in 0..<10 { mirror.environmentChanged() }
    await Task.yield()
    XCTAssertEqual(b.copies, ["disc1"])
    b.holdCopy = false; b.releaseCopy()
    await settle { mirror.state == .upToDate }
    XCTAssertEqual(b.copies, ["disc1", "disc2"])
    mirror.stop()
  }

  func testDisableRejectsLateCompletionAndCancelsImmediately() async {
    let b = Boundary(); b.holdCopy = true
    let mirror = b.make(); mirror.setEnabled(true, for: "paired")
    await settle { b.pendingCopy != nil }
    mirror.setEnabled(false, for: "paired")
    XCTAssertEqual(b.cancels, 1)
    XCTAssertEqual(mirror.state, .disabled)
    b.releaseCopy()
    await Task.yield(); await Task.yield()
    XCTAssertEqual(mirror.state, .disabled)
    XCTAssertEqual(b.copies, ["disc1"])
    XCTAssertTrue(b.scheduled.isEmpty)
  }

  func testBackgroundEmulationAndMissingPeerWaitThenResume() async {
    let b = Boundary(); b.active = false
    let mirror = b.make(); mirror.setEnabled(true, for: "paired")
    XCTAssertEqual(mirror.state, .waiting)
    b.active = true; b.emulating = true; mirror.environmentChanged()
    XCTAssertEqual(mirror.state, .waiting)
    b.emulating = false; b.discovered = []; mirror.environmentChanged()
    XCTAssertEqual(mirror.state, .waiting)
    XCTAssertTrue(b.copies.isEmpty)
    b.discovered = ["paired"]; mirror.environmentChanged()
    await settle { mirror.state == .upToDate }
    mirror.stop()
  }

  func testTrustRevocationDisablesSubscriptionAndRejectsLateCompletion() async {
    let b = Boundary(); b.holdCopy = true
    let mirror = b.make(); mirror.setEnabled(true, for: "paired")
    await settle { b.pendingCopy != nil }
    b.trusted = []; mirror.environmentChanged()
    XCTAssertTrue(mirror.enabledPeerIDs.isEmpty)
    XCTAssertEqual(b.cancels, 1)
    XCTAssertEqual(mirror.state, .disabled)
    b.releaseCopy(); await Task.yield()
    XCTAssertEqual(mirror.state, .disabled)
    XCTAssertEqual(b.copies, ["disc1"])
  }

  func testCopyFailureIsActionableAndExplicitRetryResumes() async {
    let b = Boundary(); b.failCopy = true
    let mirror = b.make(); mirror.setEnabled(true, for: "paired")
    await settle { if case .failed = mirror.state { return true }; return false }
    mirror.environmentChanged(); await Task.yield()
    XCTAssertEqual(b.copies, ["disc1"])
    b.failCopy = false; mirror.retry()
    await settle { mirror.state == .upToDate }
    XCTAssertEqual(b.copies, ["disc1", "disc1", "disc2"])
    mirror.stop()
  }

  func testRapidDisableReenableWaitsForPreviousPhysicalCopyToFinish() async {
    let b = Boundary(); b.holdCopy = true
    let mirror = b.make(); mirror.setEnabled(true, for: "paired")
    await settle { b.pendingCopy != nil }
    mirror.setEnabled(false, for: "paired")
    mirror.setEnabled(true, for: "paired")
    await Task.yield()
    XCTAssertEqual(b.copies, ["disc1"])
    b.holdCopy = false; b.releaseCopy()
    await settle { mirror.state == .upToDate }
    XCTAssertEqual(b.copies, ["disc1", "disc2"])
    mirror.stop()
  }

  func testBackgroundAndEmulationCancelAnActiveCopy() async {
    for emulation in [false, true] {
      let b = Boundary(); b.holdCopy = true
      let mirror = b.make(); mirror.setEnabled(true, for: "paired")
      await settle { b.pendingCopy != nil }
      b.active = emulation; b.emulating = emulation
      mirror.environmentChanged()
      XCTAssertEqual(b.cancels, 1)
      XCTAssertEqual(mirror.state, .waiting)
      b.releaseCopy(); await Task.yield(); await Task.yield()
      XCTAssertEqual(b.copies, ["disc1"])
      XCTAssertEqual(mirror.state, .waiting)
      mirror.stop()
    }
  }

  func testCancelledPollCallbackCannotRestartDisabledSubscription() async {
    let b = Boundary(); let mirror = b.make()
    mirror.setEnabled(true, for: "paired")
    await settle { mirror.state == .upToDate }
    let callback = b.scheduled.last!.1
    mirror.setEnabled(false, for: "paired")
    XCTAssertTrue(b.cancelledTimers.contains(0))
    callback(); await Task.yield()
    XCTAssertEqual(b.requestedPeers, ["paired"])
    XCTAssertEqual(mirror.state, .disabled)
  }

  func testUnavailableLaterPeerDoesNotLeaveFinishedPassShowingCopying() async {
    let b = Boundary(); b.holdCopy = true
    b.trusted.insert("second"); b.discovered.insert("second")
    let mirror = b.make()
    mirror.setEnabled(true, for: "paired")
    mirror.setEnabled(true, for: "second")
    await settle { b.pendingCopy != nil }
    // First pass captured only paired; the following poll captures both peers.
    b.holdCopy = false; b.releaseCopy()
    await settle { mirror.state == .upToDate }
    b.present = []; b.holdCopy = true
    b.scheduled.last?.1()
    await settle { b.pendingCopy != nil }
    b.discovered.remove("second"); mirror.environmentChanged()
    b.holdCopy = false; b.releaseCopy()
    await settle { mirror.state == .upToDate }
    XCTAssertEqual(b.requestedPeers, ["paired", "paired"])
    mirror.stop()
  }


  func testDisabledCatalogCompletionCannotBeginAnImport() async {
    let b = Boundary(); b.holdCatalog = true
    let mirror = b.make(); mirror.setEnabled(true, for: "paired")
    await settle { b.pendingCatalog != nil }
    mirror.setEnabled(false, for: "paired")
    let pending = b.pendingCatalog; b.pendingCatalog = nil
    pending?.resume(returning: b.entries)
    await Task.yield(); await Task.yield()
    XCTAssertTrue(b.copies.isEmpty)
    XCTAssertEqual(mirror.state, .disabled)
    XCTAssertTrue(b.scheduled.isEmpty)
  }

}
