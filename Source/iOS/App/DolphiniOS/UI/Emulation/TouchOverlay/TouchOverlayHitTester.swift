// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import CoreGraphics
import Foundation

/// Pure hit-test/union/delta logic for the phase 2 multi-touch surfaces (design §3). No UIKit, no
/// SwiftUI — testable the same way phase 1's geometry is. A "cluster" is one group's shared touch
/// surface (button cluster, D-pad); every live touch on that surface is hit-tested independently
/// and the results are UNIONED, so two fingers on two different buttons in the same group both
/// register, and a finger sliding from one button to another produces a release + a press rather
/// than nothing.
enum TouchOverlayHitTester {
  /// One rectangular hit region, keyed by an opaque id (a control's `TouchOverlayControl.id`).
  struct Region {
    let id: String
    let frame: CGRect
  }

  /// The union of region ids whose frame contains at least one of `touches`. Multiple touches
  /// landing in the same region contribute it once (it's a Set); a touch outside every region
  /// contributes nothing. Regions are tested in order, first match wins per touch (regions in a
  /// group's default layout never overlap — `TouchOverlayLayoutTests` checks this holds).
  static func union(touches: [CGPoint], regions: [Region]) -> Set<String> {
    var result: Set<String> = []
    for touch in touches {
      for region in regions where region.frame.contains(touch) {
        result.insert(region.id)
        break
      }
    }
    return result
  }

  /// Delta between two hit-test passes: ids that just became covered ("pressed") and ids that
  /// just stopped being covered ("released"). The caller fires exactly these transitions —
  /// never once per touch-move sample inside an already-covered region, which is the perf trap
  /// design §3 calls out (haptics/highlight on every move, not just the edge).
  static func delta<ID: Hashable>(previous: Set<ID>, now: Set<ID>) -> (pressed: Set<ID>, released: Set<ID>) {
    (pressed: now.subtracting(previous), released: previous.subtracting(now))
  }

  // MARK: D-pad angle + dead-zone bucketing

  /// A D-pad direction. `Set<DPadDirection>` of size 2 is a diagonal (adjacent cardinals only —
  /// up+down or left+right can never occur together).
  enum DPadDirection: Hashable, CaseIterable {
    case up, down, left, right
  }

  /// Direction(s) engaged by a touch at `point` within a D-pad control box of `size` (both in the
  /// control's own LOCAL coordinates, origin top-left — i.e. `point` and `size` share the same
  /// frame `TouchOverlayDefaults` gives the D-pad group). Ported from iFly's
  /// `DPadView.directions(at:in:previous:)` (§3 of the design names this as the source to copy):
  /// an 8-way octant split around the center with a circular dead-zone, plus boundary hysteresis
  /// so a finger resting on a 45° seam between two sectors doesn't chatter. This is NOT
  /// `TCDirectionalPad`'s 3x3 grid (thirds of width/height, dead center CELL, diagonals only in
  /// true corners) — that scheme doesn't do continuous 8-way sliding, which is what the shared
  /// touch surface needs. `previous` must be threaded through by the caller call-to-call for the
  /// hysteresis to have any effect; a stateless caller gets plain (non-sticky) octant bucketing.
  static func dpadDirections(at point: CGPoint, in size: CGSize,
                             previous: Set<DPadDirection>) -> Set<DPadDirection> {
    let dx = point.x - size.width / 2
    let dy = point.y - size.height / 2
    let r = (dx * dx + dy * dy).squareRoot()
    let deadzone = min(size.width, size.height) * 0.18
    guard r >= deadzone else { return [] }
    // 0 degrees = right, 90 = down (y grows downward), measured 0..<360.
    var angle = atan2(dy, dx) * 180 / .pi
    if angle < 0 { angle += 360 }
    let hysteresis = 8.0
    if let center = sectorCenter(of: previous), angularDistance(angle, center) <= 22.5 + hysteresis {
      return previous
    }
    return sector(forAngle: angle)
  }

  private static func sector(forAngle angle: Double) -> Set<DPadDirection> {
    switch angle {
    case 22.5..<67.5: return [.down, .right]
    case 67.5..<112.5: return [.down]
    case 112.5..<157.5: return [.down, .left]
    case 157.5..<202.5: return [.left]
    case 202.5..<247.5: return [.up, .left]
    case 247.5..<292.5: return [.up]
    case 292.5..<337.5: return [.up, .right]
    default: return [.right]
    }
  }

  private static func sectorCenter(of dirs: Set<DPadDirection>) -> Double? {
    switch dirs {
    case [.right]: return 0
    case [.down, .right]: return 45
    case [.down]: return 90
    case [.down, .left]: return 135
    case [.left]: return 180
    case [.up, .left]: return 225
    case [.up]: return 270
    case [.up, .right]: return 315
    default: return nil
    }
  }

  private static func angularDistance(_ a: Double, _ b: Double) -> Double {
    let d = abs(a - b).truncatingRemainder(dividingBy: 360)
    return d > 180 ? 360 - d : d
  }
}
#endif
