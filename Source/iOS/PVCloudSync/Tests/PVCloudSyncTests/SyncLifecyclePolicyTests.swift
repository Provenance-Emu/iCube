// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import PVCloudSync

/// The coordinator state machine, exercised with no network, no CloudKit
/// container and no emulator.
final class SyncLifecyclePolicyTests: XCTestCase {

    private func enabledPolicy() -> SyncLifecyclePolicy {
        var policy = SyncLifecyclePolicy(isEnabled: false)
        XCTAssertEqual(policy.handle(.enabledChanged(true)), .startSync(.enabled))
        XCTAssertEqual(policy.handle(.syncFinished), .none)
        return policy
    }

    // MARK: - Opt-in

    func testDisabledIgnoresEveryTrigger() {
        var policy = SyncLifecyclePolicy(isEnabled: false)
        XCTAssertEqual(policy.handle(.trigger(.manual)), .none)
        XCTAssertEqual(policy.handle(.trigger(.appForegrounded)), .none)
        XCTAssertEqual(policy.handle(.trigger(.fileChanged)), .none)
        XCTAssertEqual(policy.handle(.trigger(.periodicTimer)), .none)
        XCTAssertFalse(policy.isSyncing)
    }

    func testEnablingStartsASyncAndDisablingShutsDown() {
        var policy = SyncLifecyclePolicy(isEnabled: false)
        XCTAssertEqual(policy.handle(.enabledChanged(true)), .startSync(.enabled))
        XCTAssertTrue(policy.isSyncing)
        XCTAssertEqual(policy.handle(.enabledChanged(false)), .shutDown)
        XCTAssertFalse(policy.isSyncing)
        XCTAssertFalse(policy.hasDeferredWork)
    }

    func testRedundantEnabledChangeIsANoOp() {
        var policy = enabledPolicy()
        XCTAssertEqual(policy.handle(.enabledChanged(true)), .none)
    }

    // MARK: - Triggers

    func testEachTriggerStartsASyncCarryingItsReason() {
        for trigger in [SyncTrigger.appForegrounded, .appBackgrounded, .fileChanged, .periodicTimer, .manual] {
            var policy = enabledPolicy()
            XCTAssertEqual(policy.handle(.trigger(trigger)), .startSync(trigger))
        }
    }

    func testTriggersDuringARunCoalesceIntoOneFlush() {
        var policy = enabledPolicy()
        XCTAssertEqual(policy.handle(.trigger(.manual)), .startSync(.manual))

        // A burst of watcher events while the run is in flight.
        XCTAssertEqual(policy.handle(.trigger(.fileChanged)), .none)
        XCTAssertEqual(policy.handle(.trigger(.fileChanged)), .none)
        XCTAssertEqual(policy.handle(.trigger(.fileChanged)), .none)
        XCTAssertTrue(policy.hasDeferredWork)

        // Exactly one follow-up run, not three.
        XCTAssertEqual(policy.handle(.syncFinished), .startSync(.fileChanged))
        XCTAssertEqual(policy.handle(.syncFinished), .none)
    }

    // MARK: - Emulation gating

    func testTriggersWhileEmulatingAreDeferredNotRun() {
        var policy = enabledPolicy()
        XCTAssertEqual(policy.handle(.emulationWillStart), .none)

        XCTAssertEqual(policy.handle(.trigger(.fileChanged)), .deferUntilIdle)
        XCTAssertEqual(policy.handle(.trigger(.manual)), .deferUntilIdle)
        XCTAssertFalse(policy.isSyncing, "sync must never run while a game holds the files open")
        XCTAssertTrue(policy.hasDeferredWork)

        XCTAssertEqual(policy.handle(.emulationDidEnd), .startSync(.emulationEnded))
    }

    /// The case an entry guard alone cannot handle, and the reason
    /// `abortInFlightAndDefer` exists: a run is already looping over files when
    /// the user boots a game.
    func testInFlightSyncIsAbortedWhenEmulationStartsThenFlushedOnStop() {
        var policy = enabledPolicy()
        XCTAssertEqual(policy.handle(.trigger(.appForegrounded)), .startSync(.appForegrounded))
        XCTAssertTrue(policy.isSyncing)

        XCTAssertEqual(policy.handle(.emulationWillStart), .abortInFlightAndDefer)
        XCTAssertTrue(policy.hasDeferredWork)

        // The aborted loop reports back; the game is still running, so nothing starts.
        XCTAssertEqual(policy.handle(.syncFinished), .none)
        XCTAssertFalse(policy.isSyncing)
        XCTAssertTrue(policy.hasDeferredWork)

        // Game over: flush the work the game just generated.
        XCTAssertEqual(policy.handle(.emulationDidEnd), .startSync(.emulationEnded))
    }

    func testEmulationEndingWithNothingPendingDoesNotSync() {
        var policy = enabledPolicy()
        XCTAssertEqual(policy.handle(.emulationWillStart), .none)
        XCTAssertEqual(policy.handle(.emulationDidEnd), .none)
        XCTAssertFalse(policy.isSyncing)
    }

    func testEmulationStartingWithNoRunInFlightDoesNotDefer() {
        var policy = enabledPolicy()
        XCTAssertEqual(policy.handle(.emulationWillStart), .none)
        XCTAssertFalse(policy.hasDeferredWork)
    }

    func testDisablingMidRunClearsDeferredWork() {
        var policy = enabledPolicy()
        XCTAssertEqual(policy.handle(.trigger(.manual)), .startSync(.manual))
        XCTAssertEqual(policy.handle(.trigger(.fileChanged)), .none)
        XCTAssertTrue(policy.hasDeferredWork)

        XCTAssertEqual(policy.handle(.enabledChanged(false)), .shutDown)
        XCTAssertFalse(policy.hasDeferredWork)
        XCTAssertEqual(policy.handle(.syncFinished), .none, "a finished run must not restart a disabled engine")
    }

    /// Full round trip: background, game, foreground, game again.
    func testLongSequenceNeverSyncsWhileEmulating() {
        var policy = enabledPolicy()
        var actions: [SyncLifecycleAction] = []
        let events: [SyncLifecycleEvent] = [
            .trigger(.appForegrounded),
            .emulationWillStart,
            .trigger(.fileChanged),
            .syncFinished,
            .trigger(.fileChanged),
            .emulationDidEnd,
            .syncFinished,
            .trigger(.appBackgrounded),
            .syncFinished
        ]
        for event in events {
            let action = policy.handle(event)
            actions.append(action)
            if case .startSync = action {
                XCTAssertFalse(policy.isEmulating, "started a sync while emulating: \(event)")
            }
        }
        XCTAssertEqual(actions, [
            .startSync(.appForegrounded),
            .abortInFlightAndDefer,
            .deferUntilIdle,
            .none,
            .deferUntilIdle,
            .startSync(.emulationEnded),
            .none,
            .startSync(.appBackgrounded),
            .none
        ])
    }
}
