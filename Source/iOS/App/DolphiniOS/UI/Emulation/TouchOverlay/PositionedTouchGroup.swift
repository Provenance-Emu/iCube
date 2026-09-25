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
  let isEditing: Bool
  let onCommit: (CGPoint) -> Void
  /// The group's current stored size scale (§2.4) and a commit callback for a new one, or `nil`
  /// when this group isn't resizable in the editor (phase 2: the `.fill`-anchored `wiiIRPad`,
  /// whose size is a separate Settings rect in phase 3, §7 — resizing it here would have no
  /// effect since `resolvedSize(in:)` ignores stored size for `.fill`).
  let resize: (scale: CGFloat, onCommit: (CGFloat) -> Void)?
  let content: Content

  @State private var dragOffset: CGSize = .zero
  /// Live scale multiplier while a resize drag is in progress (1.0 = no change yet).
  @State private var liveScaleFactor: CGFloat = 1.0

  init(group: TouchOverlayGroup, box: CGRect, bounds: CGRect, isEditing: Bool,
       onCommit: @escaping (CGPoint) -> Void, resize: (scale: CGFloat, onCommit: (CGFloat) -> Void)? = nil,
       @ViewBuilder content: () -> Content) {
    self.group = group
    self.box = box
    self.bounds = bounds
    self.isEditing = isEditing
    self.onCommit = onCommit
    self.resize = resize
    self.content = content()
  }

  var body: some View {
    let live = CGPoint(x: box.midX + dragOffset.width, y: box.midY + dragOffset.height)
    ZStack {
      content
        .allowsHitTesting(!isEditing)
      if isEditing {
        editChrome
      }
    }
    .frame(width: box.width, height: box.height)
    .scaleEffect(liveScaleFactor)
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
}
#endif
