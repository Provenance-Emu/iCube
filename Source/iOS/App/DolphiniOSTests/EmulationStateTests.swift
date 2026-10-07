// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// `EmulationState` is the one answer to "is a game running?" for library background work. These
/// tests drive it through its own `NotificationCenter` so the app's real notifications stay out of it.
@MainActor
final class EmulationStateTests: XCTestCase {

    private var center: NotificationCenter!
    private var state: EmulationState!

    override func setUp() {
        super.setUp()
        center = NotificationCenter()
        state = EmulationState(center: center)
    }

    /// `EmulationState` hops to the main queue to apply a notification.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    func test_startsInactive() {
        XCTAssertFalse(state.isActive)
    }

    func test_willStartActivates_didEndDeactivates() {
        center.post(name: EmulationState.willStartName, object: nil)
        drainMainQueue()
        XCTAssertTrue(state.isActive)

        center.post(name: EmulationState.didEndName, object: nil)
        drainMainQueue()
        XCTAssertFalse(state.isActive)
    }

    func test_notificationNamesMatchTheOnesTheCorePosts() {
        XCTAssertEqual(EmulationState.willStartName.rawValue, "DOLEmulationWillStartNotification")
        XCTAssertEqual(EmulationState.didEndName.rawValue, "DOLEmulationDidEndNotification")
    }

    func test_didEndWithoutWillStartIsIgnored() {
        // A cancelled JIT prompt posts DidEnd for a session that never started.
        var calls = 0
        state.addTransitionHandler { _ in calls += 1 }
        center.post(name: EmulationState.didEndName, object: nil)
        drainMainQueue()
        XCTAssertFalse(state.isActive)
        XCTAssertEqual(calls, 0)
    }

    func test_repeatedDidEndNotifiesOnce() {
        // The core and the in-game screen both post DidEnd on exit.
        var transitions: [Bool] = []
        state.addTransitionHandler { transitions.append($0) }
        state.setActive(true)
        state.setActive(false)
        state.setActive(false)
        XCTAssertEqual(transitions, [true, false])
    }

    func test_handlersSeeTheUpdatedFlag() {
        var seen: [Bool] = []
        state.addTransitionHandler { [unowned state] _ in seen.append(state!.isActive) }
        state.setActive(true)
        state.setActive(false)
        XCTAssertEqual(seen, [true, false], "a handler must never observe the previous state")
    }

    func test_removedHandlerIsNotCalled() {
        var calls = 0
        let token = state.addTransitionHandler { _ in calls += 1 }
        state.removeTransitionHandler(token)
        state.setActive(true)
        XCTAssertEqual(calls, 0)
    }

    // MARK: - EmulationDeferral

    func test_deferral_runsImmediatelyWhenIdle() {
        var runs = 0
        let deferral = EmulationDeferral(state: state) { runs += 1 }
        deferral.request()
        XCTAssertEqual(runs, 1)
        XCTAssertFalse(deferral.isPending)
    }

    func test_deferral_holdsDuringASessionAndRunsOnceAtTheEnd() {
        var runs = 0
        let deferral = EmulationDeferral(state: state) { runs += 1 }
        state.setActive(true)
        deferral.request()
        deferral.request()
        deferral.request()
        XCTAssertEqual(runs, 0)
        XCTAssertTrue(deferral.isPending)

        state.setActive(false)
        XCTAssertEqual(runs, 1, "any number of requests collapse into one run")
        XCTAssertFalse(deferral.isPending)
    }

    func test_deferral_doesNotRunAtTheEndWithoutARequest() {
        var runs = 0
        _ = EmulationDeferral(state: state) { runs += 1 }
        state.setActive(true)
        state.setActive(false)
        XCTAssertEqual(runs, 0)
    }

    func test_deferral_doesNotRunWhenASessionStartsWithARequestPending() {
        var runs = 0
        let deferral = EmulationDeferral(state: state) { runs += 1 }
        deferral.request()
        XCTAssertEqual(runs, 1)
        state.setActive(true)
        XCTAssertEqual(runs, 1)
    }
}
