// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
//  WebServerLifecyclePolicy.swift
//  PVWebServer
//
//  Pure decision table for WS-3 (webserver lifecycle ownership). Before this,
//  nobody owned start/stop: iOS started the server only from a Settings-screen
//  `onAppear` (never if the user didn't open Settings), tvOS started it from
//  `TVRootView`'s `onAppear`, and `stop()` was never called by the app at all.
//
//  This type holds no I/O, no NotificationCenter, no UIKit/SwiftUI — it just
//  answers "given this event, should the app-target's single owner
//  (`WebServerLifecycleManager`) start or stop the real server?" so the
//  decision itself is unit-testable without NWListener or a running app.
public enum WebServerLifecycleEvent {
    /// The app launched or returned to the foreground (scene became active).
    case appForegrounded
    /// The app moved to the background (scene entered background).
    case appBackgrounded
    /// A game is about to start running (`DOLEmulationWillStartNotification`).
    case emulationWillStart
    /// The running game ended (`DOLEmulationDidEndNotification`).
    case emulationDidEnd
    /// A file upload began (`PVWebServerFileUploadStartedNotificationName`).
    case uploadStarted
    /// A file upload finished (`PVWebServerFileUploadCompletedNotificationName`).
    case uploadEnded
    /// A continuity handoff / nearby-library session opened (WS-4).
    ///
    /// This is the carve-out the pause-during-emulation rule was always going
    /// to need. Handing a game off happens FROM the in-game pause menu, so by
    /// the time the user asks for it the server has already been stopped by
    /// `.emulationWillStart`. "Don't stop next time" is therefore not enough —
    /// the receiving device has to be able to reach this one *now*, while the
    /// game is still running. So this event both suppresses future pauses and
    /// restarts a server this policy itself paused.
    ///
    /// The I/O-contention argument that justifies pausing during emulation
    /// (a multi-GB WebDAV upload competing with the emulator streaming a disc
    /// image off the same volume) still applies, but it is now the explicit,
    /// user-initiated cost of a feature they asked for, not a background risk
    /// taken on their behalf.
    case continuitySessionBegan
    /// A continuity session closed. When the last one closes and a game is
    /// still running, the emulation pause re-applies.
    case continuitySessionEnded
}

public enum WebServerLifecycleAction: Equatable {
    case start
    case stop
    case none
}

/// Feed it lifecycle events, get back what to do to the real server.
///
/// Two independent things can each want to stop/start the server — app
/// backgrounding and emulation — so this keeps ONE state machine as the
/// single source of truth instead of letting two call sites race. In
/// particular, a foreground event never resurrects a server that emulation
/// paused; only `emulationDidEnd` does that (see `handle(.appForegrounded...)`).
public struct WebServerLifecyclePolicy {
    public private(set) var isForeground: Bool
    public private(set) var isEmulationRunning: Bool
    public private(set) var uploadsInFlight: Int = 0
    /// Open continuity sessions. Non-zero means the server must stay reachable
    /// even while a game runs — see `.continuitySessionBegan`.
    public private(set) var continuitySessionsInFlight: Int = 0
    /// True once this policy told the caller to stop the server specifically
    /// because emulation started. Only `emulationDidEnd` may clear it, so a
    /// foreground event during a running game can never restart it early.
    public private(set) var pausedForEmulation: Bool = false

    public init(isForeground: Bool = true, isEmulationRunning: Bool = false) {
        self.isForeground = isForeground
        self.isEmulationRunning = isEmulationRunning
    }

    /// - Parameter serverIsRunning: the real server's current `isRunning`, read
    ///   fresh by the caller right before calling this — the policy never
    ///   guesses at server state on its own.
    @discardableResult
    public mutating func handle(
        _ event: WebServerLifecycleEvent,
        serverIsRunning: Bool
    ) -> WebServerLifecycleAction {
        switch event {
        case .appForegrounded:
            isForeground = true
            // Only `pausedForEmulation` gates a restart here, not `isEmulationRunning`.
            // `pausedForEmulation` is set exactly when WE stopped the server for a game,
            // so only `emulationDidEnd` may resurrect it — that's what stops a foreground
            // event from racing an emulation-driven stop (see the lifecycle tests). But
            // `isEmulationRunning` alone must NOT block a start: if a game is reported
            // running yet the server was never running to begin with (e.g. its async
            // NWListener bind was still in flight when the game booted — see
            // WebServerLifecycleService's known limitation) or `DOLEmulationDidEndNotification`
            // is ever missed on an abandoned boot, gating on it too would leave the server
            // dead for the rest of the app session with no way to recover.
            guard !serverIsRunning, !pausedForEmulation else { return .none }
            return .start

        case .appBackgrounded:
            isForeground = false
            // Neither app declares any UIBackgroundModes entitlement, so iOS
            // suspends the whole process shortly after this fires regardless of
            // what we do here — the NWListener socket is frozen along with it
            // (not torn down) and resumes automatically the moment the process
            // is un-suspended on foreground. Explicitly stopping here would only
            // (a) unpublish and immediately republish Bonjour on every
            // background/foreground cycle, and (b) hand a WebDAV client (e.g. a
            // Finder mount, per the sleep/wake acceptance bar) a connection
            // reset with no compensating benefit. So: deliberately do nothing.
            return .none

        case .emulationWillStart:
            isEmulationRunning = true
            // Only pause a server we're actually running, and only if nothing
            // is mid-transfer — killing an in-flight upload because the user
            // happened to boot a game a second later would be a worse bug than
            // the one this task exists to fix.
            // …and only if no continuity session is open: a peer mid-pull, or a
            // handoff the user just started, needs this device reachable for the
            // whole game session.
            guard serverIsRunning, uploadsInFlight == 0, continuitySessionsInFlight == 0 else { return .none }
            pausedForEmulation = true
            return .stop

        case .emulationDidEnd:
            isEmulationRunning = false
            guard pausedForEmulation else { return .none }
            pausedForEmulation = false
            guard isForeground else { return .none }
            return .start

        case .uploadStarted:
            uploadsInFlight += 1
            return .none

        case .uploadEnded:
            uploadsInFlight = max(0, uploadsInFlight - 1)
            return .none

        case .continuitySessionBegan:
            continuitySessionsInFlight += 1
            // Clearing `pausedForEmulation` is what makes the restart stick: it
            // is the flag that otherwise blocks every later `.appForegrounded`
            // start, and leaving it set would mean a session that opened
            // mid-game got its server back only until the user switched apps.
            // Ownership of the "is a game running" pause moves to
            // `continuitySessionsInFlight` for as long as a session is open.
            pausedForEmulation = false
            guard !serverIsRunning, isForeground else { return .none }
            return .start

        case .continuitySessionEnded:
            continuitySessionsInFlight = max(0, continuitySessionsInFlight - 1)
            // Re-apply the emulation pause once the last session closes, so the
            // carve-out lasts exactly as long as the feature needs it.
            guard continuitySessionsInFlight == 0, isEmulationRunning, serverIsRunning else { return .none }
            pausedForEmulation = true
            return .stop
        }
    }
}
