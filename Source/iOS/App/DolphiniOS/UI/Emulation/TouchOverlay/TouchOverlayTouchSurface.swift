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

  /// One live touch's identity (stable for its lifetime), current location in the surface's own
  /// coordinate space, and its force reading (task item 2, phase 3: force-sensitive analog
  /// triggers). `force`/`maximumPossibleForce` are `0` on hardware/touch types that don't report
  /// one (e.g. no 3D/haptic Touch support) — see `TouchOverlayInput.pressureValue`'s fallback.
  struct Touch {
    let id: ObjectIdentifier
    let location: CGPoint
    let force: CGFloat
    let maximumPossibleForce: CGFloat
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
      let points = touches.map {
        Touch(id: ObjectIdentifier($0), location: $0.location(in: self),
              force: $0.force, maximumPossibleForce: $0.maximumPossibleForce)
      }
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
  /// Ids that should report continuous touch-force while held (task item 2, phase 3:
  /// force-sensitive analog triggers). Empty by default — most clusters (plain buttons, D-pads)
  /// don't need this.
  var pressureIds: Set<ID> = []
  /// Fired on every touch update (NOT gated by the press/release delta `onChange` uses, since
  /// pressure is continuous data) for a touch whose OWN hit region — not the cluster-wide union —
  /// is one of `pressureIds`.
  var onForce: ((ID, Float) -> Void)?
  /// Fired with the locations (surface-local) of touches that just landed, once per touch-down and never
  /// for a finger that moves in. For things that must act on a fresh touch only (skin menu/quick-save).
  var onBegan: (([CGPoint]) -> Void)?

  /// The fingers on this surface. A reference box rather than `@State` on purpose: nothing draws from
  /// it, and a `@State` rewritten on every move sample (120 Hz while a finger is down) re-ran this
  /// body, its `GeometryReader` and the surface's `updateUIView` for every sample. Only `pressed`,
  /// which changes once per press or release, may invalidate the view.
  @State private var liveTouches = TouchOverlayLiveTouches()

  var body: some View {
    // swiftlint:disable:next redundant_discardable_let
    let _ = TouchOverlayRenderProbe.body(.cluster)
    GeometryReader { geo in
      TouchOverlaySurface { phase, touches in
        liveTouches.apply(phase, touches)
        if phase == .began { onBegan?(touches.map(\.location)) }
        recompute(in: geo.size)
      }
      .contentShape(Rectangle())
      .onDisappear { releaseAll() }
    }
  }

  private func recompute(in size: CGSize) {
    let update = TouchOverlayClusterUpdate(previous: pressed, touches: liveTouches.values) { hitTest($0, size) }
    let (pressedNow, releasedNow) = (update.pressed, update.released)
    for id in releasedNow { onChange(id, false) }
    for id in pressedNow { onChange(id, true) }
    // Only on a real change: assigning an equal set still invalidates every view reading the binding
    // (the whole button cluster's art), once per move sample.
    if update.changed { pressed = update.now }

    guard let onForce, !pressureIds.isEmpty else { return }
    // Task item 2 (DSU pass): a newly-pressed `pressureIds` member gets EXACTLY ONE analog write
    // this pass, from `onForce` — never also the caller's own `onChange(id, true)` fallback (see
    // `TouchOverlayGroupViews.axisButton`'s onChange case, which now writes 0.0 on release only).
    // Before this, `onChange`'s synthetic 1.0 and this loop's real force sample raced within the
    // SAME pass: on force-reporting hardware (Apple Pencil, 3D-Touch-era iPhones) a light press
    // sent a full-value DSU packet immediately followed by a lower one, an edge a DSU client could
    // read as a full press-then-release of the mirrored shoulder button.
    var coveredThisPass: Set<ID> = []
    for touch in liveTouches.values {
      let hits = hitTest(touch.location, size)
      guard hits.count == 1, let id = hits.first, pressureIds.contains(id) else { continue }
      onForce(id, TouchOverlayInput.pressureValue(force: touch.force, maximumPossibleForce: touch.maximumPossibleForce))
      coveredThisPass.insert(id)
    }
    // A `pressureIds` member that just became pressed but wasn't covered above (e.g. two touches
    // landed on the SAME region in the same instant, so `hits.count != 1` for both) still needs an
    // initial analog value — `onChange`'s own axisButton write is gone now, so nothing else will
    // ever send one. `1.0` matches `TouchOverlayInput.pressureValue`'s own no-force convention.
    for id in pressedNow where pressureIds.contains(id) && !coveredThisPass.contains(id) {
      onForce(id, 1.0)
    }
  }

  /// Release every currently-covered region — used on `onDisappear` (the surface vanishing mid-
  /// press, e.g. the pause menu opening) and by the editor's "release everything" on entering edit
  /// mode, so a control can never stick down.
  func releaseAll() {
    for id in pressed { onChange(id, false) }
    if !pressed.isEmpty { pressed = [] }
    liveTouches.removeAll()
  }
}

/// The live touches on one cluster surface, by touch identity. A plain reference type, so updating
/// it on every move sample never invalidates SwiftUI (see `TouchOverlayCluster.liveTouches`).
/// Main thread only, like the UIKit touch callbacks that feed it.
final class TouchOverlayLiveTouches {
  private var touches: [ObjectIdentifier: TouchOverlaySurface.Touch] = [:]

  var values: Dictionary<ObjectIdentifier, TouchOverlaySurface.Touch>.Values { touches.values }

  /// Records a began/moved touch's latest location and force, and forgets an ended/cancelled one.
  func apply(_ phase: TouchOverlaySurface.Phase, _ updated: [TouchOverlaySurface.Touch]) {
    switch phase {
    case .began, .moved:
      for touch in updated { touches[touch.id] = touch }
    case .ended, .cancelled:
      for touch in updated { touches.removeValue(forKey: touch.id) }
    }
  }

  func removeAll() {
    touches.removeAll()
  }
}

/// One cluster recompute: the regions every live touch covers now, and what changed since `previous`.
/// Pure, so the "fire only the delta, write `pressed` only on a change" rule is unit-testable.
struct TouchOverlayClusterUpdate<ID: Hashable> {
  let now: Set<ID>
  let pressed: Set<ID>
  let released: Set<ID>

  /// False when every touch still covers exactly what it did: a finger sliding inside one button.
  var changed: Bool { !pressed.isEmpty || !released.isEmpty }

  init<Touches: Sequence>(previous: Set<ID>, touches: Touches, hitTest: (CGPoint) -> Set<ID>)
  where Touches.Element == TouchOverlaySurface.Touch {
    var covered: Set<ID> = []
    for touch in touches { covered.formUnion(hitTest(touch.location)) }
    now = covered
    (pressed, released) = TouchOverlayHitTester.delta(previous: previous, now: covered)
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
