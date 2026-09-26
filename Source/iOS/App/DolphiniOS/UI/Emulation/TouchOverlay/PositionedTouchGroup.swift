// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI

/// One draggable control group in the layout editor, ported near-verbatim from iFly's
/// `PositionedControlGroup` (design §0/§4). In normal play it renders `content` at `box` with
/// input fully live; in edit mode the content's own input is suppressed and a dashed handle
/// captures a drag — the group follows the finger and commits on release via
/// `TouchOverlayLayoutEngine.resolve` (free placement, clamped on-screen only; no grid-snap or
/// overlap rejection, matching phase 1's engine).
struct PositionedTouchGroup<Content: View>: View {
  let group: TouchOverlayGroup
  let box: CGRect
  let bounds: CGRect
  /// True whenever ANY `TouchOverlayEditMode` is active, regardless of whether THIS group is the
  /// one being edited — governs input only (`allowsHitTesting`). Split from `showsChrome` (task
  /// item 1, design §9's IR-area/layout-edit mutual exclusion): before the IR pad's rectangle got
  /// its own dedicated `.irArea` editor, "is any edit happening" and "does THIS group show
  /// chrome" were the same question, because `.layout` mode always meant both together for every
  /// group. They no longer are — in `.irArea` mode every group's input must still be suppressed
  /// (a face button must not stay live under the editor) even though only `wiiIRPad` shows chrome.
  let inputSuppressed: Bool
  /// True only for the group(s) the current `TouchOverlayEditMode` lets the user manipulate
  /// (`TouchOverlayEditMode.showsChrome(for:)`).
  let showsChrome: Bool
  let onCommit: (CGPoint) -> Void
  /// The group's current stored UNIFORM size scale (§2.4) and a commit callback for a new one, or
  /// `nil` when this group isn't resizable this way — either because it doesn't resize at all, or
  /// because it uses `resizeAxes` instead (today only `wiiIRPad` in `.irArea` mode). Mutually
  /// exclusive with `resizeAxes` in practice (`TouchOverlayView` sets at most one per group per
  /// edit mode), not enforced structurally since both are independent optionals.
  let resize: (scale: CGFloat, onCommit: (CGFloat) -> Void)?
  /// Independent horizontal/vertical size scale and commit callback (task item 1's "Edit IR Area"
  /// editor; design §7's "[x, y, w, h] normalized" ask). Unlike `resize`'s single corner handle
  /// that scales both axes together, `wiiIRPad`'s rectangle needs to become a short strip or a
  /// tall column, not just a bigger/smaller version of its `.fillInset` default — see
  /// `resizeAxesHandle`.
  let resizeAxes: (scale: CGSize, onCommit: (CGSize) -> Void)?
  let content: Content

  @State private var dragOffset: CGSize = .zero
  /// Live scale multiplier while a `resize` drag is in progress (1.0 = no change yet).
  @State private var liveScaleFactor: CGFloat = 1.0
  /// Live PER-AXIS scale multipliers while a `resizeAxes` drag is in progress.
  @State private var liveScaleFactorX: CGFloat = 1.0
  @State private var liveScaleFactorY: CGFloat = 1.0

  init(group: TouchOverlayGroup, box: CGRect, bounds: CGRect, inputSuppressed: Bool, showsChrome: Bool,
       onCommit: @escaping (CGPoint) -> Void, resize: (scale: CGFloat, onCommit: (CGFloat) -> Void)? = nil,
       resizeAxes: (scale: CGSize, onCommit: (CGSize) -> Void)? = nil,
       @ViewBuilder content: () -> Content) {
    self.group = group
    self.box = box
    self.bounds = bounds
    self.inputSuppressed = inputSuppressed
    self.showsChrome = showsChrome
    self.onCommit = onCommit
    self.resize = resize
    self.resizeAxes = resizeAxes
    self.content = content()
  }

  var body: some View {
    let live = CGPoint(x: box.midX + dragOffset.width, y: box.midY + dragOffset.height)
    ZStack {
      content
        .allowsHitTesting(!inputSuppressed)
      if showsChrome {
        editChrome
      }
    }
    .frame(width: box.width, height: box.height)
    .scaleEffect(x: liveScaleFactor * liveScaleFactorX, y: liveScaleFactor * liveScaleFactorY)
    .position(live)
  }

  private var editChrome: some View {
    ZStack(alignment: .bottomTrailing) {
      RoundedRectangle(cornerRadius: 14)
        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.14)))
        .overlay(
          Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.caption.weight(.bold))
            .foregroundColor(.white)
            .padding(6)
            .background(Circle().fill(Color.accentColor.opacity(0.9)))
        )
        .contentShape(Rectangle())
        .gesture(moveGesture)
      if let resize {
        resizeHandle(resize)
      }
      if let resizeAxes {
        resizeAxesHandle(resizeAxes)
      }
    }
    .frame(width: box.width, height: box.height)
  }

  private var moveGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in dragOffset = value.translation }
      .onEnded { value in
        let proposed = CGPoint(x: box.midX + value.translation.width, y: box.midY + value.translation.height)
        let resolved = TouchOverlayLayoutEngine.resolve(proposed: proposed, size: box.size, bounds: bounds)
        onCommit(resolved)
        dragOffset = .zero
      }
  }

  /// A small corner grip: dragging away from the box grows it, toward it shrinks it. The delta is
  /// normalized by the box's own size so the gesture feels roughly linear regardless of the
  /// group's footprint; the store clamps the committed scale to `TouchOverlayLayoutStore.scaleRange`
  /// regardless of what this preview shows mid-drag.
  private func resizeHandle(_ resize: (scale: CGFloat, onCommit: (CGFloat) -> Void)) -> some View {
    Image(systemName: "arrow.up.left.and.arrow.down.right")
      .font(.caption2.weight(.bold))
      .foregroundColor(.white)
      .padding(6)
      .background(Circle().fill(Color.orange.opacity(0.9)))
      .offset(x: 10, y: 10)
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            let base = max(box.width, box.height, 1)
            let delta = (value.translation.width + value.translation.height) / base
            liveScaleFactor = max(0.4, 1 + delta)
          }
          .onEnded { value in
            let base = max(box.width, box.height, 1)
            let delta = (value.translation.width + value.translation.height) / base
            resize.onCommit(resize.scale * max(0.4, 1 + delta))
            liveScaleFactor = 1.0
          }
      )
  }

  /// The IR area editor's resize grip (task item 1): unlike `resizeHandle`'s single corner (which
  /// scales both axes by the SAME factor), this reads the horizontal and vertical drag components
  /// independently, so dragging mostly sideways widens the IR pad's rect without also growing its
  /// height (and vice versa) — the "short strip or tall column" shape design §7 asks for that a
  /// uniform scale can't produce. The commit-side clamp (`TouchOverlayIRGeometry.
  /// clampFillInsetScale`, via `TouchOverlayLayoutStore.setIRSizeScale`) is bounds-aware, not just
  /// `scaleRange`-limited like `resizeHandle`'s — see that function's doc comment.
  private func resizeAxesHandle(_ resize: (scale: CGSize, onCommit: (CGSize) -> Void)) -> some View {
    Image(systemName: "arrow.up.left.and.arrow.down.right")
      .font(.caption2.weight(.bold))
      .foregroundColor(.white)
      .padding(6)
      .background(Circle().fill(Color.orange.opacity(0.9)))
      .offset(x: 10, y: 10)
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            liveScaleFactorX = max(0.3, 1 + value.translation.width / max(box.width, 1))
            liveScaleFactorY = max(0.3, 1 + value.translation.height / max(box.height, 1))
          }
          .onEnded { value in
            let sx = max(0.3, 1 + value.translation.width / max(box.width, 1))
            let sy = max(0.3, 1 + value.translation.height / max(box.height, 1))
            resize.onCommit(CGSize(width: resize.scale.width * sx, height: resize.scale.height * sy))
            liveScaleFactorX = 1.0
            liveScaleFactorY = 1.0
          }
      )
  }
}
#endif
