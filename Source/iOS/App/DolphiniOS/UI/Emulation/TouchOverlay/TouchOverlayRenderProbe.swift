// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation
import os

/// Marks every body evaluation of the on-screen controls' hot views, so a device run can show how
/// often touching the controls re-renders them. Each call emits a Points of Interest signpost (visible
/// in Instruments' Time Profiler and System Trace with no custom instrument; near free when nothing is
/// recording) and, in DEBUG builds, bumps a counter tests read. Call it from `body` as
/// `let _ = TouchOverlayRenderProbe.body(.cluster)`.
///
/// What to expect: a finger sliding inside one button, or resting on the D-pad, should emit nothing
/// after the press; a moving stick emits only `stickKnob`/`skinStickKnob`, once per move sample.
enum TouchOverlayRenderProbe {
  enum Site: String, CaseIterable {
    /// `TouchOverlayCluster`, the shared multi-touch surface of a button group, D-pad or skin.
    case cluster
    /// `TouchOverlayButtonClusterView`: every button's art in one group.
    case buttonCluster
    case dpad
    /// `TouchOverlayStickView`'s container (base + knob).
    case stick
    case stickBase
    case stickKnob
    /// A skin's thumbstick knob (`SkinStickView`).
    case skinStickKnob
  }

  private static let signposter = OSSignposter(
    subsystem: Bundle.main.bundleIdentifier ?? "org.dolphin-emu.dolphinios", category: .pointsOfInterest)

  static func body(_ site: Site) {
    signposter.emitEvent("OverlayBody", "\(site.rawValue, privacy: .public)")
    #if DEBUG
    lock.lock()
    counts[site, default: 0] += 1
    lock.unlock()
    #endif
  }

  #if DEBUG
  private static let lock = NSLock()
  private static var counts: [Site: Int] = [:]

  /// Body evaluations of `site` since launch or the last `reset()`.
  static func count(_ site: Site) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return counts[site, default: 0]
  }

  static func reset() {
    lock.lock()
    counts.removeAll()
    lock.unlock()
  }
  #endif
}
#endif
