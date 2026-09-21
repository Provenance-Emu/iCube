// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Detects a boot that never got past its resume/boot-into-state load, so the
// NEXT launch can decline the same auto-resume instead of re-entering the same
// hang forever (WS-1 item 1d/1c).
//
// Mirrors JitManager's TXM-handshake pattern exactly (kTXMHandshakeInFlightKey /
// beginTXMHandshake / noteTXMHandshakeResult / txmHandshakeBlocked in
// JitManager.m): persist a sticky marker in NSUserDefaults BEFORE the risky step
// (synchronized to disk immediately, since the step might hang or crash before
// anything else runs), and only clear it once something proves the step didn't
// take down the app. A marker still set at the next launch is proof the previous
// attempt never got that far.
//
// ObjC visibility: `@objc`/NSObject so TVEmulationBridge.mm (ObjC++) can call
// `[BootWatchdog clear]` from `+stop` (a clean exit is one of the two "we got
// past it" signals) through the generated iCube-Swift.h.

import Foundation

@objc(BootWatchdog)
public final class BootWatchdog: NSObject {
  private static let inFlightKey = "ICubeBootWatchdogInFlight"

  /// True at launch iff a previous boot attempt armed the watchdog and nothing
  /// ever cleared it — i.e. that attempt never confirmed it got past its resume
  /// (or boot-into-state) load, whether by hanging or by crashing outright.
  @objc public static var previousBootNeverCompleted: Bool {
    UserDefaults.standard.bool(forKey: inFlightKey)
  }

  /// Call immediately before issuing a resume/boot-into-state load — the step
  /// that has actually caused hangs (a bad auto-state). `synchronize()` so the
  /// marker reaches disk even if the process is about to hang or get killed.
  @objc public static func armBeforeBoot() {
    let defaults = UserDefaults.standard
    defaults.set(true, forKey: inFlightKey)
    defaults.synchronize()
  }

  /// Call on a clean exit (`TVEmulationBridge.stop`) or once the boot has been
  /// confirmed alive (`clearAfterLivenessWindow`). Either is proof the load did
  /// not take the app down.
  @objc public static func clear() {
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: inFlightKey)
    defaults.synchronize()
  }

  /// Best-effort "we got past the risky load" signal. There is no lower-level
  /// "first frame presented" hook to clear on precisely (that would mean
  /// instrumenting the Metal presenter — see the CLAUDE.md Metal rendering
  /// gotchas), so this approximates it with a liveness window: if the main run
  /// loop is still alive to run this closure after `seconds`, the app did not
  /// freeze outright. A genuine crash or a main-thread deadlock (including one
  /// caused by the emulation thread holding a lock the main thread waits on —
  /// see the `@synchronized(self)` gotcha in CLAUDE.md) leaves the marker set,
  /// which is exactly the case the next launch needs to see. Not caught: a hang
  /// confined to the emulation thread alone that never blocks the main thread or
  /// crashes the process — a narrower failure mode than the "app won't come back
  /// up" loop this watchdog exists for.
  @objc public static func clearAfterLivenessWindow(seconds: TimeInterval = 3.0) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
      clear()
    }
  }
}
