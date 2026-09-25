// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI
import UIKit

/// Raw UIKit multi-touch surface, ported near-verbatim from iFly's `MultiTouchView` (design §3 /
/// §0 table: "the one file worth taking from Skins/"). SwiftUI's `DragGesture` is single-touch and
/// stays bound to the view it began on, which is exactly what makes sliding a finger between two
/// adjacent buttons, or holding a D-pad direction while pressing a face button, impossible with
/// per-control gesture recognizers. `touchesBegan/Moved/Ended/Cancelled` with
/// `isMultipleTouchEnabled` sidesteps that: UIKit already routes each touch to whichever view is
/// under it, so ONE surface per control GROUP (not per app) is enough to get cross-group
/// multi-touch for free.
struct TouchOverlaySurface: UIViewRepresentable {
  enum Phase {
    case began, moved, ended, cancelled
  }

  /// One live touch's identity (stable for its lifetime) and current location in the surface's
  /// own coordinate space.
  struct Touch {
    let id: ObjectIdentifier
    let location: CGPoint
  }

  let onTouches: (Phase, [Touch]) -> Void

  func makeUIView(context: Context) -> SurfaceView {
    let view = SurfaceView()
    view.onTouches = onTouches
    return view
  }

  func updateUIView(_ uiView: SurfaceView, context: Context) {
    uiView.onTouches = onTouches
  }

  final class SurfaceView: UIView {
    var onTouches: ((Phase, [Touch]) -> Void)?

    override init(frame: CGRect) {
      super.init(frame: frame)
      sharedInit()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      sharedInit()
    }

    private func sharedInit() {
      isMultipleTouchEnabled = true
      isUserInteractionEnabled = true
      backgroundColor = .clear
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { report(.began, touches) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { report(.moved, touches) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { report(.ended, touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { report(.cancelled, touches) }

    private func report(_ phase: Phase, _ touches: Set<UITouch>) {
      let points = touches.map { Touch(id: ObjectIdentifier($0), location: $0.location(in: self)) }
      onTouches?(phase, points)
    }
  }
}

/// A shared multi-touch surface driving a CLUSTER of controls (button group, D-pad) from ONE
/// gesture, ported from iFly's `MultiTouchCluster` (design §0/§3). Every touch event recomputes
/// the UNION of hit regions covered by ALL live touches on this surface and fires ONLY the delta —
/// so feedback (haptics, highlight) never re-fires on every move sample inside an already-pressed
/// region (the perf trap design §3 documents), and two fingers on two different controls in the
/// same group both register.
struct TouchOverlayCluster<ID: Hashable>: View {
  /// Maps one touch's location (surface-local) + the surface size to the region id(s) it covers.
  let hitTest: (CGPoint, CGSize) -> Set<ID>
  /// Fired once per transition: `true` when a region becomes covered, `false` when it stops.
  let onChange: (ID, Bool) -> Void
  /// The live covered set, exposed so the caller can drive press-state art off it.
  @Binding var pressed: Set<ID>

  @State private var liveTouches: [ObjectIdentifier: CGPoint] = [:]

  var body: some View {
    GeometryReader { geo in
      TouchOverlaySurface { phase, touches in
        switch phase {
        case .began, .moved:
          for touch in touches { liveTouches[touch.id] = touch.location }
        case .ended, .cancelled:
          for touch in touches { liveTouches.removeValue(forKey: touch.id) }
        }
        recompute(in: geo.size)
      }
      .contentShape(Rectangle())
      .onDisappear { releaseAll() }
    }
  }

  private func recompute(in size: CGSize) {
    var now: Set<ID> = []
    for location in liveTouches.values { now.formUnion(hitTest(location, size)) }
    let (pressedNow, releasedNow) = TouchOverlayHitTester.delta(previous: pressed, now: now)
    for id in releasedNow { onChange(id, false) }
    for id in pressedNow { onChange(id, true) }
    pressed = now
  }

  /// Release every currently-covered region — used on `onDisappear` (the surface vanishing mid-
  /// press, e.g. the pause menu opening) and by the editor's "release everything" on entering edit
  /// mode, so a control can never stick down.
  func releaseAll() {
    for id in pressed { onChange(id, false) }
    pressed = []
    liveTouches = [:]
  }
}

/// A single-touch tracker for the analog stick: unlike the button/D-pad clusters, a stick has no
/// discrete regions to union — it reports the FIRST touch's continuous location and ignores any
/// others, exactly like a real thumbstick only has one contact point. `onChange(nil)` on release
/// tells the caller to recenter.
struct TouchOverlaySingleTouch: View {
  let onChange: (CGPoint?) -> Void

  @State private var activeTouchId: ObjectIdentifier?

  var body: some View {
    TouchOverlaySurface { phase, touches in
      switch phase {
      case .began:
        guard activeTouchId == nil, let first = touches.first else { return }
        activeTouchId = first.id
        onChange(first.location)
      case .moved:
        guard let active = activeTouchId, let touch = touches.first(where: { $0.id == active }) else { return }
        onChange(touch.location)
      case .ended, .cancelled:
        guard let active = activeTouchId, touches.contains(where: { $0.id == active }) else { return }
        activeTouchId = nil
        onChange(nil)
      }
    }
    .contentShape(Rectangle())
    .onDisappear {
      guard activeTouchId != nil else { return }
      activeTouchId = nil
      onChange(nil)
    }
  }
}
#endif
