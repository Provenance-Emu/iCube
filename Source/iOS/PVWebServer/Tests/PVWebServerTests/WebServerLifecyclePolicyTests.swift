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
