// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI
import UIKit

/// Phase 3 port of `TCWiiPad`'s drag/follow IR pointer (design §6.5/§6.6, task item 1) onto the
/// `wiiIRPad` group. A raw `UIView` subclass, not `TouchOverlayCluster`/`TouchOverlaySingleTouch`
/// — this needs direct access to `self` to convert `TVEmulationBridge.currentVideoContentRect()`
/// into its own coordinate space at gesture time, exactly as `TCWiiPad.recalculatePointerValues`
/// / `layoutSubviews` did, and needs `touchesBegan/Moved/Ended/Cancelled`'s per-touch identity to
/// track one "primary" touch across a drag while a three-finger hold is tracked independently.
///
/// Writes ONLY through `TCManagerInterface.setAxisValueFor` on ids 112-115 with the SAME
/// `[y, y, x, x]` convention as `TCWiiPad.sendIR` (design §6.4 — this is IR-specific and must not
/// be "fixed" to the stick's half-axis convention).
struct TouchOverlayIRPadView: UIViewRepresentable {
  /// `.none` (gyro-mode setting, or IR fully disabled) keeps this surface inert and lets
  /// `TCDeviceMotion.handleIRCursorMapping` keep driving 112-115 unchanged (design §6.6 — never
  /// route gyro mode through this view).
  let mode: TCWiiTouchIRMode
  let deviceId: Int
  /// Every OTHER group's resolved box, in THIS view's own local coordinate space (i.e. already
  /// offset by the IR pad's own box origin) — the belt-and-braces exclusion check
  /// (`TouchOverlayIRGeometry.touchStartAllowed`). Empty when there's nothing to exclude.
  let excludedFrames: [CGRect]
  /// `TouchOverlayEditMode.inputSuppressed` — true in EITHER edit mode (`.layout` or `.irArea`),
  /// not just when the IR pad itself is the thing being edited, so a layout-editor drag over some
  /// OTHER group can't also nudge the pointer underneath it.
  let isEditing: Bool
  /// Drag-mode pointer sensitivity (task item 1's "Pointer Sensitivity" setting,
  /// `touch_overlay_ir_pointer_gain`, already clamped by `TouchOverlayIRGeometry.clampDragGain`).
  /// Follow mode ignores this (see `TouchOverlayIRGeometry.follow`'s doc comment).
  let dragGain: CGFloat

  func makeUIView(context: Context) -> IRSurfaceView { IRSurfaceView() }

  func updateUIView(_ uiView: IRSurfaceView, context: Context) {
    uiView.mode = mode
    uiView.deviceId = deviceId
    uiView.excludedFrames = excludedFrames
    uiView.dragGain = dragGain
    uiView.isEditingFlag = isEditing
  }

  /// Mirrors `TCView`'s `willMove(toSuperview:)`/`deinit` clear-on-teardown pattern
  /// (TCView.swift's "Defect #7" comment) for this raw `UIViewRepresentable`: SwiftUI doesn't
  /// guarantee `dismantleUIView` runs on every path that removes this view (in particular
  /// `TouchPadsContainer` dropping the WHOLE hosting view when the overlay stops being the right
  /// pad to show), but `IRSurfaceView.willMove(toSuperview:)`/`deinit` (below) catch that case
  /// independently. This override handles the path SwiftUI DOES own: the `.irSurface` layout
  /// entry disappearing from the `ForEach` (e.g. a `padKind` switch away from Wii) while the
  /// hosting view itself stays mounted, which `willMove`/`deinit` alone would miss since the
  /// `UIView` doesn't leave a superview in that case.
  static func dismantleUIView(_ uiView: IRSurfaceView, coordinator: ()) {
    uiView.forceReleaseAndCenter()
  }

  final class IRSurfaceView: UIView {
    var mode: TCWiiTouchIRMode = .none {
      didSet {
        guard mode != oldValue else { return }
        // `TCWiiPad.setTouchIRMode`: center between mode changes for predictable handoff. When
        // the NEW mode is `.none`, `sendIR`'s own guard makes this a state reset with no write.
        forceReleaseAndCenter()
      }
    }
    var deviceId: Int = 0
    var excludedFrames: [CGRect] = []
    var dragGain: CGFloat = 1.0
    var isEditingFlag: Bool = false {
      didSet {
        guard isEditingFlag != oldValue else { return }
        isUserInteractionEnabled = !isEditingFlag
        if isEditingFlag { forceReleaseAndCenter() }
      }
    }

    private var primaryTouch: UITouch?
    private var touchStartPoint: CGPoint = .zero
    private var oldX: CGFloat = 0
    private var oldY: CGFloat = 0
    private var activeTouches: Set<UITouch> = []
    private var threeFingerWorkItem: DispatchWorkItem?

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
      backgroundColor = .clear
    }

    /// Mirrors `TCView`'s own `willMove(toSuperview:)`/`deinit` pair (its "Defect #7" comment) so
    /// a mid-drag IR pointer can never stick at a stale non-center value if `TouchPadsContainer`
    /// removes the hosting view directly (task item 2's DSU pass): per-group SwiftUI teardown
    /// (`TouchOverlayCluster.releaseAll()` on `onDisappear`, `dismantleUIView` above) covers the
    /// overlay's own internal transitions, but not the hosting view being torn out from under
    /// SwiftUI entirely.
    override func willMove(toSuperview newSuperview: UIView?) {
      super.willMove(toSuperview: newSuperview)
      if newSuperview == nil { forceReleaseAndCenter() }
    }

    deinit {
      // Covers deallocation WITHOUT a preceding `willMove(toSuperview: nil)` (e.g. the whole
      // hosting view tree being released at once, which doesn't necessarily walk each subview's
      // `willMove` first). `forceReleaseAndCenter` only reads plain stored properties
      // (`mode`/`deviceId`, already fully initialized) and calls a static method, so it's safe to
      // run this late; it's a private cancel/reset timer plus a handful of `TCManagerInterface`
      // writes, nothing that re-enters `self` through ARC.
      forceReleaseAndCenter()
    }

    // MARK: Geometry (read live, never cached — see TouchOverlayIRGeometry's header comment)

    private func currentGameRect() -> CGRect {
      let aspectRatio = CGFloat(TVEmulationBridge.currentDrawAspectRatio())
      let videoRect = TVEmulationBridge.currentVideoContentRect()
      let localRect: CGRect
      if videoRect == .zero {
        localRect = bounds
      } else if let main = EmulationCoordinator.shared().mainDisplayView() {
        localRect = convert(videoRect, from: main)
      } else {
        localRect = bounds
      }
      let rect = localRect.isEmpty ? bounds : localRect
      return TouchOverlayIRGeometry.letterboxedGameRect(in: rect, aspectRatio: aspectRatio)
    }

    // MARK: Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
      super.touchesBegan(touches, with: event)
      activeTouches.formUnion(touches)
      scheduleThreeFingerCheckIfNeeded()
      guard mode != .none, primaryTouch == nil else { return }
      // Exclusion rule (design §6.5): a touch that started inside another group never begins an
      // IR gesture. In practice this surface sits below every other group in the ZStack so such a
      // touch is delivered elsewhere first; this is the belt-and-braces guard.
      guard let touch = touches.first(where: { isTouchAllowed($0) }) else { return }
      primaryTouch = touch
      touchStartPoint = touch.location(in: self)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
      super.touchesMoved(touches, with: event)
      guard mode != .none, let primary = primaryTouch, touches.contains(primary) else { return }
      let point = primary.location(in: self)
      sendIR(computeXY(at: point))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
      super.touchesEnded(touches, with: event)
      activeTouches.subtract(touches)
      scheduleThreeFingerCheckIfNeeded()
      finishPrimaryTouch(in: touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
      super.touchesCancelled(touches, with: event)
      activeTouches.subtract(touches)
      scheduleThreeFingerCheckIfNeeded()
      // Task item 2's DSU pass (a real, now-fixed bug, not just a naming difference from
      // `touchesEnded`): this used to only clear `primaryTouch`, doing NOTHING else on a
      // cancellation (an incoming call, the app backgrounding mid-drag, the system reassigning the
      // touch to a gesture recognizer elsewhere). In `.drag` mode that left `oldX`/`oldY` — the
      // "continue from here" memory `handleLongPress`'s persistence emulates — stuck at whatever
      // the PREVIOUS completed drag had left them at, even though `StateManager`/DSU's actual axis
      // state reflected the cancelled gesture's last `touchesMoved` sample. The NEXT drag would
      // then accumulate its delta onto that stale base instead of the visually-last position,
      // desyncing the pointer from where the finger actually was. Routing cancellation through the
      // SAME finish path as `touchesEnded` (send the current position, persist it in drag mode)
      // fixes the desync without the visible "snap to center" a recenter-on-cancel would cause
      // mid-aim on something as routine as an edge-swipe interruption.
      finishPrimaryTouch(in: touches)
    }

    /// Shared by `touchesEnded`/`touchesCancelled`: both a natural lift and a cancellation report
    /// the SAME last-known position via `UITouch.location(in:)` (still valid post-cancel), so both
    /// should send it and, in `.drag` mode, persist it as the next drag's starting point.
    private func finishPrimaryTouch(in touches: Set<UITouch>) {
      guard mode != .none, let primary = primaryTouch, touches.contains(primary) else { return }
      let point = primary.location(in: self)
      let (x, y) = computeXY(at: point)
      sendIR((x, y))
      if mode == .drag {
        // `TCWiiPad.handleLongPress`: persist the released position so the next drag continues
        // from here instead of snapping back.
        oldX = x
        oldY = y
      }
      primaryTouch = nil
    }

    private func isTouchAllowed(_ touch: UITouch) -> Bool {
      TouchOverlayIRGeometry.touchStartAllowed(at: touch.location(in: self), excluding: excludedFrames)
    }

    private func computeXY(at point: CGPoint) -> (x: CGFloat, y: CGFloat) {
      let rect = currentGameRect()
      switch mode {
      case .none:
        return (0, 0)
      case .follow:
        return TouchOverlayIRGeometry.follow(point: point, in: rect)
      case .drag:
        return TouchOverlayIRGeometry.drag(start: touchStartPoint, current: point, oldX: oldX, oldY: oldY, in: rect, gain: dragGain)
      }
    }

    // MARK: Three-finger hold to recenter (`TCWiiPad.handleThreeFingerHold`)

    private func scheduleThreeFingerCheckIfNeeded() {
      threeFingerWorkItem?.cancel()
      threeFingerWorkItem = nil
      guard activeTouches.count == 3 else { return }
      let heldTouches = activeTouches
      let work = DispatchWorkItem { [weak self] in
        guard let self, self.activeTouches == heldTouches else { return }
        self.forceReleaseAndCenter()
      }
      threeFingerWorkItem = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    // MARK: Reset / center

    /// Releases any in-progress gesture and centers the pointer — used on a mode change, an
    /// edit-mode transition, and the three-finger-hold gesture. `sendIR`'s own `mode != .none`
    /// guard means this is a pure state reset (no write) when the current mode is `.none`.
    func forceReleaseAndCenter() {
      threeFingerWorkItem?.cancel()
      threeFingerWorkItem = nil
      primaryTouch = nil
      touchStartPoint = .zero
      oldX = 0
      oldY = 0
      sendIR((0, 0))
    }

    private func sendIR(_ xy: (x: CGFloat, y: CGFloat)) {
      guard mode != .none else { return }
      // Writes the SAME value to both members of each IR pair (112/113 = Up/Down, 114/115 =
      // Left/Right) — `TCWiiPad.sendIR`'s convention, do not "fix" this to the stick's
      // half-axis convention (design §6.4).
      let axisStartIdx = TCButtonType.wiiInfrared.rawValue
      for (offset, axis) in [xy.y, xy.y, xy.x, xy.x].enumerated() {
        TCManagerInterface.setAxisValueFor(axisStartIdx + offset + 1, controller: deviceId, value: Float(axis))
      }
    }
  }
}
#endif
