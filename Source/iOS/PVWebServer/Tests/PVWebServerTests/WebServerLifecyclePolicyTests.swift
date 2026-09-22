import XCTest
@testable import PVWebServer

final class WebServerLifecyclePolicyTests: XCTestCase {

    // MARK: - Fresh install / foreground

    func testForegroundStartsAStoppedServer() {
        var policy = WebServerLifecyclePolicy()
        XCTAssertEqual(policy.handle(.appForegrounded, serverIsRunning: false), .start)
    }

    func testForegroundIsANoOpWhenAlreadyRunning() {
        var policy = WebServerLifecyclePolicy()
        XCTAssertEqual(policy.handle(.appForegrounded, serverIsRunning: true), .none)
    }

    // MARK: - Backgrounding never stops the server (no UIBackgroundModes)

    func testBackgroundingIsAlwaysANoOp() {
        var policy = WebServerLifecyclePolicy()
        XCTAssertEqual(policy.handle(.appBackgrounded, serverIsRunning: true), .none)
        XCTAssertFalse(policy.isForeground)
        XCTAssertEqual(policy.handle(.appBackgrounded, serverIsRunning: false), .none)
    }

    // MARK: - Emulation pause/resume

    func testEmulationStartStopsARunningServer() {
        var policy = WebServerLifecyclePolicy()
        XCTAssertEqual(policy.handle(.emulationWillStart, serverIsRunning: true), .stop)
        XCTAssertTrue(policy.pausedForEmulation)
        XCTAssertTrue(policy.isEmulationRunning)
    }

    func testEmulationStartIsANoOpWhenServerAlreadyStopped() {
        var policy = WebServerLifecyclePolicy()
        XCTAssertEqual(policy.handle(.emulationWillStart, serverIsRunning: false), .none)
        XCTAssertFalse(policy.pausedForEmulation)
    }

    func testEmulationStartNeverKillsAnInFlightUpload() {
        var policy = WebServerLifecyclePolicy()
        XCTAssertEqual(policy.handle(.uploadStarted, serverIsRunning: true), .none)
        XCTAssertEqual(policy.handle(.emulationWillStart, serverIsRunning: true), .none)
        XCTAssertFalse(policy.pausedForEmulation)
    }

    func testEmulationEndRestartsOnlyTheServerItPaused() {
        var policy = WebServerLifecyclePolicy()
        XCTAssertEqual(policy.handle(.emulationWillStart, serverIsRunning: true), .stop)
        XCTAssertEqual(policy.handle(.emulationDidEnd, serverIsRunning: false), .start)
        XCTAssertFalse(policy.pausedForEmulation)
    }

    func testEmulationEndIsANoOpWhenWeNeverPausedIt() {
        // e.g. the user had already stopped the server manually before the game started.
        var policy = WebServerLifecyclePolicy()
        XCTAssertEqual(policy.handle(.emulationWillStart, serverIsRunning: false), .none)
        XCTAssertEqual(policy.handle(.emulationDidEnd, serverIsRunning: false), .none)
    }

    func testEmulationEndDoesNotRestartIfAppIsBackgrounded() {
        var policy = WebServerLifecyclePolicy()
        XCTAssertEqual(policy.handle(.emulationWillStart, serverIsRunning: true), .stop)
        XCTAssertEqual(policy.handle(.appBackgrounded, serverIsRunning: false), .none)
        XCTAssertEqual(policy.handle(.emulationDidEnd, serverIsRunning: false), .none)
        // Once we're back in the foreground, nothing auto-starts it — that's
        // fine, the next appForegrounded (or manual open) will.
        XCTAssertFalse(policy.pausedForEmulation)
    }

    // MARK: - The bug the advisor caught: foreground must not race emulation's pause

    func testForegroundDuringAPausedGameDoesNotRestartTheServer() {
        var policy = WebServerLifecyclePolicy()
        XCTAssertEqual(policy.handle(.emulationWillStart, serverIsRunning: true), .stop)
        // App is backgrounded and returns to foreground while the game is still running.
        XCTAssertEqual(policy.handle(.appBackgrounded, serverIsRunning: false), .none)
        XCTAssertEqual(policy.handle(.appForegrounded, serverIsRunning: false), .none)
        XCTAssertTrue(policy.pausedForEmulation)
        // Only ending emulation restarts it.
        XCTAssertEqual(policy.handle(.emulationDidEnd, serverIsRunning: false), .start)
    }

    // MARK: - isEmulationRunning alone must never strand the server stopped

    func testForegroundStartsEvenIfEmulationIsReportedRunningButWeNeverPausedIt() {
        // Guards against a stuck `isEmulationRunning` (e.g. a missed DidEnd on an
        // abandoned boot, or the async-start race where the server was still binding
        // when emulationWillStart fired) permanently blocking every future restart.
        // Only `pausedForEmulation` — the flag WE set when WE stopped it — may gate this.
        var policy = WebServerLifecyclePolicy()
        XCTAssertEqual(policy.handle(.emulationWillStart, serverIsRunning: false), .none)
        XCTAssertTrue(policy.isEmulationRunning)
        XCTAssertFalse(policy.pausedForEmulation)
        XCTAssertEqual(policy.handle(.appForegrounded, serverIsRunning: false), .start)
    }

    // MARK: - Upload counting never goes negative

    func testUploadCountFloorsAtZero() {
        var policy = WebServerLifecyclePolicy()
        XCTAssertEqual(policy.handle(.uploadEnded, serverIsRunning: true), .none)
        XCTAssertEqual(policy.uploadsInFlight, 0)
    }
}

// MARK: - WS-4 continuity carve-out

extension WebServerLifecyclePolicyTests {

    /// The headline case: the user boots a game (server pauses), then opens the
    /// pause menu and hands the game off. The server must come back.
    func testContinuitySessionDuringAGameRestartsAPausedServer() {
        var policy = WebServerLifecyclePolicy()
        XCTAssertEqual(policy.handle(.emulationWillStart, serverIsRunning: true), .stop)
        XCTAssertTrue(policy.pausedForEmulation)

        XCTAssertEqual(policy.handle(.continuitySessionBegan, serverIsRunning: false), .start)
        XCTAssertFalse(policy.pausedForEmulation)
        XCTAssertEqual(policy.continuitySessionsInFlight, 1)
    }

    /// Backgrounding and returning mid-session must not re-pause the server:
    /// `pausedForEmulation` has to have been cleared, not just overridden.
    func testForegroundDuringAContinuitySessionStillStarts() {
        var policy = WebServerLifecyclePolicy()
        policy.handle(.emulationWillStart, serverIsRunning: true)
        policy.handle(.continuitySessionBegan, serverIsRunning: false)

        policy.handle(.appBackgrounded, serverIsRunning: true)
        XCTAssertEqual(policy.handle(.appForegrounded, serverIsRunning: false), .start)
    }

    func testEmulationStartIsNotAllowedToPauseWhileASessionIsOpen() {
        var policy = WebServerLifecyclePolicy()
        XCTAssertEqual(policy.handle(.continuitySessionBegan, serverIsRunning: true), .none)
        XCTAssertEqual(policy.handle(.emulationWillStart, serverIsRunning: true), .none)
        XCTAssertFalse(policy.pausedForEmulation)
    }

    func testClosingTheLastSessionReappliesTheEmulationPause() {
        var policy = WebServerLifecyclePolicy()
        policy.handle(.emulationWillStart, serverIsRunning: true)
        policy.handle(.continuitySessionBegan, serverIsRunning: false)

        XCTAssertEqual(policy.handle(.continuitySessionEnded, serverIsRunning: true), .stop)
        XCTAssertTrue(policy.pausedForEmulation)
        XCTAssertEqual(policy.continuitySessionsInFlight, 0)
    }

    func testSessionsAreCountedSoAConcurrentPullKeepsTheServerUp() {
        var policy = WebServerLifecyclePolicy()
        policy.handle(.emulationWillStart, serverIsRunning: true)
        policy.handle(.continuitySessionBegan, serverIsRunning: false)
        policy.handle(.continuitySessionBegan, serverIsRunning: true)
        XCTAssertEqual(policy.continuitySessionsInFlight, 2)

        XCTAssertEqual(policy.handle(.continuitySessionEnded, serverIsRunning: true), .none)
        XCTAssertFalse(policy.pausedForEmulation)
        XCTAssertEqual(policy.handle(.continuitySessionEnded, serverIsRunning: true), .stop)
    }

    func testClosingTheLastSessionWithNoGameRunningLeavesTheServerUp() {
        var policy = WebServerLifecyclePolicy()
        policy.handle(.continuitySessionBegan, serverIsRunning: true)
        XCTAssertEqual(policy.handle(.continuitySessionEnded, serverIsRunning: true), .none)
        XCTAssertFalse(policy.pausedForEmulation)
    }

    func testUnbalancedSessionEndCannotDriveTheCounterNegative() {
        var policy = WebServerLifecyclePolicy()
        policy.handle(.continuitySessionEnded, serverIsRunning: true)
        XCTAssertEqual(policy.continuitySessionsInFlight, 0)
        // A later real session still works.
        policy.handle(.emulationWillStart, serverIsRunning: true)
        XCTAssertEqual(policy.handle(.continuitySessionBegan, serverIsRunning: false), .start)
    }

    func testSessionBeganWhileBackgroundedDoesNotStartTheServer() {
        var policy = WebServerLifecyclePolicy()
        policy.handle(.emulationWillStart, serverIsRunning: true)
        policy.handle(.appBackgrounded, serverIsRunning: false)
        XCTAssertEqual(policy.handle(.continuitySessionBegan, serverIsRunning: false), .none)
    }

    // MARK: - User-requested access outranks the emulation pause

    func testOpeningImportDuringAGameStartsTheServer() {
        var policy = WebServerLifecyclePolicy(isForeground: true, isEmulationRunning: false)
        XCTAssertEqual(policy.handle(.emulationWillStart, serverIsRunning: true), .stop)
        XCTAssertTrue(policy.pausedForEmulation)
        // The user opens the Wi-Fi import sheet mid-game.
        XCTAssertEqual(policy.handle(.userRequestedAccess, serverIsRunning: false), .start)
        XCTAssertFalse(policy.pausedForEmulation,
                       "clearing the flag is what stops the next foreground event killing it again")
    }

    func testClosingImportReappliesTheEmulationPause() {
        var policy = WebServerLifecyclePolicy(isForeground: true, isEmulationRunning: true)
        XCTAssertEqual(policy.handle(.userRequestedAccess, serverIsRunning: false), .start)
        XCTAssertEqual(policy.handle(.userReleasedAccess, serverIsRunning: true), .stop)
        XCTAssertTrue(policy.pausedForEmulation)
    }

    func testEmulationDoesNotPauseWhileImportIsOpen() {
        var policy = WebServerLifecyclePolicy(isForeground: true, isEmulationRunning: false)
        XCTAssertEqual(policy.handle(.userRequestedAccess, serverIsRunning: true), .none)
        XCTAssertEqual(policy.handle(.emulationWillStart, serverIsRunning: true), .none,
                       "a game booting must not yank the server out from under an open import sheet")
        XCTAssertFalse(policy.pausedForEmulation)
    }

    func testNestedRequestsAreBalanced() {
        var policy = WebServerLifecyclePolicy(isForeground: true, isEmulationRunning: true)
        XCTAssertEqual(policy.handle(.userRequestedAccess, serverIsRunning: false), .start)
        XCTAssertEqual(policy.handle(.userRequestedAccess, serverIsRunning: true), .none)
        XCTAssertEqual(policy.handle(.userReleasedAccess, serverIsRunning: true), .none,
                       "one surface closing must not stop the server while another is open")
        XCTAssertEqual(policy.handle(.userReleasedAccess, serverIsRunning: true), .stop)
    }
}
