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
            guard serverIsRunning, uploadsInFlight == 0 else { return .none }
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
        }
    }
}
