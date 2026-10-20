import Foundation
import XCTest

@MainActor final class HarnessMirror {
  var wakeCount = 0
  var onWake: (() -> Void)?
  func environmentChanged() { wakeCount += 1; onWake?() }
}
@MainActor enum LibraryMetadataService {
  static var resumeCount = 0
  static func resumeContentIdentityWarming() { resumeCount += 1 }
}
@MainActor final class ContinuityManager {
  static let shared = ContinuityManager()
  let libraryMirror = HarnessMirror()
}

@MainActor final class CloudSyncDrainWakeTests: XCTestCase {
  override func setUp() { super.setUp() }
  func testUIDidEndCannotWakeUntilAcceptedPhysicalDrain() async {
    let mirror = ContinuityManager.shared.libraryMirror
    let before = mirror.wakeCount
    let beforeWarm = LibraryMetadataService.resumeCount
    let generation = SyncLocalIOGate.shared.beginEmulation()
    await CloudSyncCoordinator.shared.handle(.emulationDidEnd)
    XCTAssertEqual(mirror.wakeCount, before)
    XCTAssertTrue(SyncLocalIOGate.shared.isEmulating)
    let wake = expectation(description: "physical drain wakes nearby mirror")
    mirror.onWake = { wake.fulfill() }
    ICubeCloudSyncBootGate.finishCoreDrain(generation)
    await fulfillment(of: [wake], timeout: 1)
    mirror.onWake = nil
    XCTAssertEqual(mirror.wakeCount, before + 1)
    XCTAssertEqual(LibraryMetadataService.resumeCount, beforeWarm + 1)
  }
  func testStaleWorkerDrainCannotWakeNewBoot() async {
    let mirror = ContinuityManager.shared.libraryMirror
    let before = mirror.wakeCount
    let beforeWarm = LibraryMetadataService.resumeCount
    let old = SyncLocalIOGate.shared.beginEmulation()
    let current = SyncLocalIOGate.shared.beginEmulation()
    ICubeCloudSyncBootGate.finishCoreDrain(old)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(mirror.wakeCount, before)
    XCTAssertTrue(SyncLocalIOGate.shared.isCurrentEmulation(current))
    XCTAssertEqual(LibraryMetadataService.resumeCount, beforeWarm)
    _ = SyncLocalIOGate.shared.finishCoreDrain(generation: current)
  }
  func testNewBootBeforeQueuedDrainDeliverySuppressesWake() async {
    let mirror = ContinuityManager.shared.libraryMirror
    let before = mirror.wakeCount
    let beforeWarm = LibraryMetadataService.resumeCount
    let old = SyncLocalIOGate.shared.beginEmulation()
    ICubeCloudSyncBootGate.finishCoreDrain(old)
    let current = SyncLocalIOGate.shared.beginEmulation()
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(mirror.wakeCount, before)
    XCTAssertTrue(SyncLocalIOGate.shared.isCurrentEmulation(current))
    XCTAssertEqual(LibraryMetadataService.resumeCount, beforeWarm)
    _ = SyncLocalIOGate.shared.finishCoreDrain(generation: current)
  }
}
