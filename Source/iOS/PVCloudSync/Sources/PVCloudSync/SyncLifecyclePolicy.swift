// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Why a sync was asked for. Carried through to the log so a device boot log
/// says what churned and why.
public enum SyncTrigger: String, Sendable, Equatable {
    case enabled
    case appForegrounded
    case appBackgrounded
    case fileChanged
    case periodicTimer
    case manual
    /// Flush of work that was deferred while a game was running.
    case emulationEnded
}

/// Something that happened which the sync engine has to react to.
public enum SyncLifecycleEvent: Sendable, Equatable {
    case trigger(SyncTrigger)
    /// A game is about to boot.
    case emulationWillStart
    /// The running game stopped.
    case emulationDidEnd
    /// The sync run that was in flight has finished (successfully or not).
    case syncFinished
    /// The user flipped the sync toggle.
    case enabledChanged(Bool)
}

/// What the caller should do about it.
public enum SyncLifecycleAction: Sendable, Equatable {
    /// Begin a sync run now.
    case startSync(SyncTrigger)
    /// A run is in flight and a game just started: bail out of the loop at the
    /// next file boundary. The work is remembered and flushed on stop.
    case abortInFlightAndDefer
    /// Remembered for later; do nothing now.
    case deferUntilIdle
    /// Tear everything down (watchers, timer, in-flight run).
    case shutDown
    case none
}

/// The sync coordinator's state machine, with no I/O in it.
///
/// Same shape as WS-3's `WebServerLifecyclePolicy`: the app-side coordinator is
/// NotificationCenter glue that feeds events in and performs the returned
/// action, and every interesting rule lives here where it can be tested without
/// a network, a CloudKit container, or a running emulator.
///
/// The rules, in the order they bite:
///
/// - **Sync is gated off entirely while emulating.** Dolphin holds save states,
///   memory cards and the Wii NAND open while a game runs; writing under it is
///   how a save gets corrupted. Every trigger that arrives mid-game is remembered
///   rather than run.
/// - **An in-flight run must be aborted, not merely blocked.** An entry guard
///   alone does nothing about a sync that is already looping over files, which
///   is exactly the case that matters: the user taps a game while a foreground
///   sync is still uploading. Hence `abortInFlightAndDefer`.
/// - **Deferred work is flushed on stop**, because the game just wrote the very
///   files worth syncing.
/// - **Triggers coalesce.** A burst of watcher events during a run leaves one
///   pending flush, not one run per event.
public struct SyncLifecyclePolicy: Sendable, Equatable {

    public private(set) var isEnabled: Bool
    public private(set) var isEmulating: Bool = false
    public private(set) var isSyncing: Bool = false
    /// A trigger arrived at a moment when it could not be run.
    public private(set) var hasDeferredWork: Bool = false

    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    public mutating func handle(_ event: SyncLifecycleEvent) -> SyncLifecycleAction {
        switch event {
        case .enabledChanged(let enabled):
            guard enabled != isEnabled else { return .none }
            isEnabled = enabled
            if enabled {
                return begin(.enabled)
            }
            isEmulating = false
            isSyncing = false
            hasDeferredWork = false
            return .shutDown

        case .trigger(let trigger):
            guard isEnabled else { return .none }
            // Never touch files a running core has open.
            guard !isEmulating else {
                hasDeferredWork = true
                return .deferUntilIdle
            }
            // Coalesce: one pending flush, however many events arrived.
            guard !isSyncing else {
                hasDeferredWork = true
                return .none
            }
            return begin(trigger)

        case .emulationWillStart:
            isEmulating = true
            guard isSyncing else { return .none }
            // The run keeps going until its loop notices; remember to finish it.
            hasDeferredWork = true
            return .abortInFlightAndDefer

        case .emulationDidEnd:
            isEmulating = false
            return flushIfPending(as: .emulationEnded)

        case .syncFinished:
            isSyncing = false
            guard !isEmulating else { return .none }
            return flushIfPending(as: .fileChanged)
        }
    }

    /// Enter the syncing state and tell the caller to run.
    private mutating func begin(_ trigger: SyncTrigger) -> SyncLifecycleAction {
        isSyncing = true
        hasDeferredWork = false
        return .startSync(trigger)
    }

    private mutating func flushIfPending(as trigger: SyncTrigger) -> SyncLifecycleAction {
        guard isEnabled, hasDeferredWork, !isSyncing, !isEmulating else { return .none }
        return begin(trigger)
    }
}
