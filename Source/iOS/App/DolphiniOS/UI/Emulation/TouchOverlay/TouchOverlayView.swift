// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI

/// The programmatic touch overlay's SwiftUI root (design §3/§4/§8 phase 2), behind the
/// `touch_overlay_programmatic` flag. `GeometryReader` + `ZStack` of one `PositionedTouchGroup`
/// (or, for the `.fill`-anchored `wiiIRPad`, a plain inert layer) per
/// `TouchOverlayDefaults.layout(for:orientation:)` entry — a port of iFly's
/// `VirtualControllerOverlay.body`/`consoleLayout` shape, generalized over `TouchOverlayPadKind`
/// instead of a single console.
struct TouchOverlayView: View {
  let padKind: TouchOverlayPadKind
  /// The Touchscreen device id (`ControllerManager.shared.touchscreenControllerId(isWii:)`) —
  /// NEVER the player slot (design §6.3). Named explicitly, not `port`, per the design's own
  /// call-out of that exact mix-up as a historical bug source.
  let deviceId: Int

  @ObservedObject private var store = TouchOverlayLayoutStore.shared
  @State private var isEditing = false

  var body: some View {
    GeometryReader { geo in
      let bounds = CGRect(origin: .zero, size: geo.size)
      let orientation = TouchOverlayOrientation(isPortrait: geo.size.height >= geo.size.width)
      let layouts = TouchOverlayDefaults.layout(for: padKind, orientation: orientation)
      let opacity = isEditing ? 1.0 : max(0.2, Double(DOLConfigBridge.mainTouchPadOpacity()))
      let variant: TouchOverlayArt.Variant = padKind == .gameCube ? .gameCube : .wii
      // `revision` isn't read directly, but touching it here ties this body's re-evaluation to
      // every store mutation (position AND size-scale writes), matching phase 1's store contract.
      // NOTE: must stay a `let` declaration, not a bare `_ = ...` assignment — inside a
      // `@ViewBuilder` closure a bare assignment statement is itself treated as a View-producing
      // expression (type `()`, which doesn't conform to `View`) and fails to build.
      // swiftlint:disable:next redundant_discardable_let
      let _ = store.revision

      // `.fill`-anchored groups (today, only `wiiIRPad`) must paint FIRST (bottom of the ZStack):
      // they cover the whole overlay, so drawn last they'd sit visually on top of every button/
      // D-pad/stick despite being `allowsHitTesting(false)` — a translucent white layer over
      // everything else. `TouchOverlayDefaults` doesn't guarantee ordering (it lists `wiiIRPad`
      // last for the Wii Remote pad), so partition explicitly rather than relying on array order.
      let fillLayouts = layouts.filter { $0.placement.anchor == .fill }
      let positionedLayouts = layouts.filter { $0.placement.anchor != .fill }

      ZStack {
        // Long-press-to-edit lives on a background layer BELOW every control surface, not on the
        // whole ZStack: attaching it to the container would let UIKit's ancestor gesture
        // recognizer cancel an in-progress touch on a button/D-pad/stick underneath it (its
        // default `cancelsTouchesInView` would force-release whatever was held), turning an
        // ordinary half-second button hold into an accidental edit-mode entry. A touch that lands
        // on a group's own surface is consumed there and never reaches this layer; only a touch on
        // genuinely empty overlay space does — matching the task's "long-press on empty overlay
        // space" wording.
        Color.clear
          .contentShape(Rectangle())
          .onLongPressGesture(minimumDuration: 0.5) {
            guard !isEditing else { return }
            isEditing = true
          }

        ForEach(fillLayouts, id: \.group) { layout in
          groupView(layout: layout, bounds: bounds, orientation: orientation, opacity: opacity, variant: variant)
        }
        ForEach(positionedLayouts, id: \.group) { layout in
          groupView(layout: layout, bounds: bounds, orientation: orientation, opacity: opacity, variant: variant)
        }
        if isEditing {
          editToolbar
        }
      }
      .ignoresSafeArea()
    }
  }

  // MARK: Per-group dispatch

  @ViewBuilder
  private func groupView(layout: TouchOverlayGroupLayout, bounds: CGRect, orientation: TouchOverlayOrientation,
                         opacity: Double, variant: TouchOverlayArt.Variant) -> some View {
    if layout.placement.anchor == .fill {
      // Inert IR surface (§2.1/§6.5): the whole overlay, never hit-testable, not part of the
      // drag/resize editor (its stored position/scale would have no rendering effect — see the
      // phase 2 plan doc).
      content(for: layout, scale: 1.0, isEditing: false, variant: variant)
        .opacity(opacity)
        .frame(width: bounds.width, height: bounds.height)
        .position(x: bounds.midX, y: bounds.midY)
        .allowsHitTesting(false)
    } else {
      let scale = store.sizeScale(for: layout.group, padKind: padKind, orientation: orientation)
      let box = store.resolvedBox(for: layout, padKind: padKind, orientation: orientation, in: bounds)
      PositionedTouchGroup(
        group: layout.group, box: box, bounds: bounds, isEditing: isEditing,
        onCommit: { resolved in
          store.setCenter(resolved, in: bounds, for: layout.group, padKind: padKind, orientation: orientation)
        },
        resize: (scale: scale, onCommit: { newScale in
          let defaultCenter = layout.placement.center(in: bounds)
          store.setSizeScale(newScale, for: layout.group, padKind: padKind, orientation: orientation,
                             defaultCenter: TouchOverlayLayoutEngine.normalize(defaultCenter, in: bounds))
        }),
        content: {
          content(for: layout, scale: scale, isEditing: isEditing, variant: variant)
            .opacity(opacity)
        }
      )
    }
  }

  @ViewBuilder
  private func content(for layout: TouchOverlayGroupLayout, scale: CGFloat, isEditing: Bool,
                       variant: TouchOverlayArt.Variant) -> some View {
    let groupSize = CGSize(width: layout.size.width * scale, height: layout.size.height * scale)
    if layout.controls.count == 1, case .dpad(let baseId) = layout.controls[0].kind {
      TouchOverlayDPadView(baseId: baseId, deviceId: deviceId, variant: variant, groupSize: groupSize, isEditing: isEditing)
    } else if layout.controls.count == 1, case .stick(let baseId) = layout.controls[0].kind {
      TouchOverlayStickView(baseId: baseId, deviceId: deviceId, variant: variant, groupSize: groupSize, isEditing: isEditing)
    } else if layout.controls.count == 1, case .irSurface = layout.controls[0].kind {
      TouchOverlayIRPadView(variant: variant)
    } else {
      TouchOverlayButtonClusterView(controls: layout.controls, deviceId: deviceId, variant: variant,
                                    groupSize: groupSize, scale: scale, isEditing: isEditing)
    }
  }

  // MARK: Edit chrome

  private var editToolbar: some View {
    VStack {
      HStack {
        Spacer()
        HStack(spacing: 8) {
          Button {
            store.reset(padKind: padKind)
          } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
          }
          .buttonStyle(.bordered)

          Button {
            isEditing = false
          } label: {
            Label("Done", systemImage: "checkmark")
          }
          .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding()
      }
      Spacer()
    }
  }
}
#endif
