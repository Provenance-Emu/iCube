import Foundation
import XCTest
#if !LIVE_PERFORMANCE_HOST_TESTS
@testable import iCube
#endif

final class LivePerformanceOwnershipTests: XCTestCase {
  func testOpeningAndClosingDoNotRequestPauseAndPreserveUnrelatedHold() {
    let state = LivePerformanceOwnership()
    var unrelatedPause = true
    XCTAssertTrue(state.open(session: "game:1"))
    state.close()
    XCTAssertFalse(state.isPresented)
    XCTAssertTrue(unrelatedPause)
    unrelatedPause = false
  }
  func testPauseIsClaimedBeforeClosing() {
    let state = LivePerformanceOwnership()
    _ = state.open(session: "game:1")
    var events: [String] = []
    state.transitionToPause { events.append(state.isPresented ? "claimed-before-close" : "too-late") }
    XCTAssertEqual(events, ["claimed-before-close"])
    XCTAssertFalse(state.isPresented)
    state.transitionToPause { XCTFail("Closed panels must not claim another pause") }
  }
  func testSessionChangeAndBackgroundCloseWithoutResume() {
    let state = LivePerformanceOwnership()
    _ = state.open(session: "a")
    state.reconcile(session: "b")
    XCTAssertFalse(state.isPresented)
    _ = state.open(session: "b")
    state.reconcile(session: nil)
    XCTAssertFalse(state.isPresented)
    _ = state.open(session: "c")
    state.close()
    XCTAssertFalse(state.isPresented)
  }
  func testOpeningFenceAndSelectAreReleaseGated() {
    var input = LivePerformanceRemoteInput()
    XCTAssertEqual(input.poll(horizontal: 0, vertical: 1, select: true, now: 0), [])
    XCTAssertEqual(input.poll(horizontal: 0, vertical: 0, select: false, now: 1), [])
    XCTAssertEqual(input.poll(horizontal: 0, vertical: -1, select: true, now: 2), [.down, .select])
    XCTAssertEqual(input.poll(horizontal: 0, vertical: -1, select: true, now: 2.1), [])
    XCTAssertEqual(input.poll(horizontal: 0, vertical: -1, select: true, now: 2.5), [.down])
    XCTAssertEqual(input.poll(horizontal: 0, vertical: 0, select: false, now: 3), [])
    XCTAssertEqual(input.poll(horizontal: 0, vertical: 0, select: true, now: 4), [.select])
  }
  func testClosingLeaseWaitsForNeutralAndDisconnectOnlyReleasesExactRemote() {
    let fence = LivePerformanceReleaseFence<NSObject>()
    let remote = NSObject(), other = NSObject()
    var neutral = false
    var requested = 0, disconnected = 0
    fence.retain(controller: remote, request: { requested += 1 }, poll: { neutral }, disconnect: { disconnected += 1 })
    XCTAssertEqual(requested, 1)
    fence.reap(connected: [remote, other])
    XCTAssertFalse(fence.isEmpty)
    XCTAssertEqual(disconnected, 0)
    neutral = true
    fence.reap(connected: [remote])
    XCTAssertTrue(fence.isEmpty)
    fence.retain(controller: remote, request: {}, poll: { false }, disconnect: { disconnected += 1 })
    fence.reap(connected: [other])
    XCTAssertTrue(fence.isEmpty)
    XCTAssertEqual(disconnected, 1)
  }
  func testDuplicateOpenKeepsCurrentSessionAndSessionChangeCloses() {
    let state = LivePerformanceOwnership()
    XCTAssertTrue(state.open(session: "first"))
    XCTAssertFalse(state.open(session: "second"))
    state.reconcile(session: "first")
    XCTAssertTrue(state.isPresented)
    state.reconcile(session: "second")
    XCTAssertFalse(state.isPresented)
  }
  func testDirectionChangeAndRepeatAreBounded() {
    var input = LivePerformanceRemoteInput()
    _ = input.poll(horizontal: 0, vertical: 0, select: false, now: 0)
    XCTAssertEqual(input.poll(horizontal: 1, vertical: 0, select: false, now: 1), [.right])
    XCTAssertEqual(input.poll(horizontal: -1, vertical: 0, select: false, now: 1.01), [.left])
    XCTAssertEqual(input.poll(horizontal: -1, vertical: 0, select: false, now: 99), [.left])
    XCTAssertEqual(input.poll(horizontal: -1, vertical: 0, select: false, now: 99.01), [])
  }
}
