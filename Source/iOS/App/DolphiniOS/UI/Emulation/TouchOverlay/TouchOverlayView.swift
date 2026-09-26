// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI

/// The programmatic touch overlay's SwiftUI root (design §3/§4/§8 phase 2, IR wiring + settings
/// phase 3), behind the `touch_overlay_programmatic` flag. `GeometryReader` + `ZStack` of one
/// `PositionedTouchGroup` per `TouchOverlayDefaults.layout(for:orientation:)` entry — a port of
/// iFly's `VirtualControllerOverlay.body`/`consoleLayout` shape, generalized over
/// `TouchOverlayPadKind` instead of a single console.
struct TouchOverlayView: View {
  let padKind: TouchOverlayPadKind
  /// The Touchscreen device id (`ControllerManager.shared.touchscreenControllerId(isWii:)`) —
  /// NEVER the player slot (design §6.3). Named explicitly, not `port`, per the design's own
  /// call-out of that exact mix-up as a historical bug source.
  let deviceId: Int
  /// `TCWiiTouchIRMode`'s raw value (`DOLConfigBridge.mainTouchPadIRMode()`, threaded down from
  /// `TouchPadsContainer.irMode`). Only meaningful for the Wii Remote pad kind's `wiiIRPad` group.
  let irMode: Int

  @ObservedObject private var store = TouchOverlayLayoutStore.shared
  @State private var editMode: TouchOverlayEditMode

  /// - Parameter initialEditMode: opens straight into an edit mode, for the Settings
  ///   "Edit Layout…" / "Edit IR Area…" previews (task items 1/3) — those previews have no live
  ///   game/device context, so every group's input is suppressed from the first frame
  ///   (`TouchOverlayEditMode.inputSuppressed`), and no `TCManagerInterface` write can happen
  ///   regardless of the placeholder `deviceId` those sheets pass. Those sheets also pass
  ///   `irMode: .none` themselves so the IR pad's `mode`/`isEditingFlag` transition on mount
  ///   can't send a stray "recenter" write either (see `TouchOverlayIRPadView`'s doc comment).
  init(padKind: TouchOverlayPadKind, deviceId: Int, irMode: Int, initialEditMode: TouchOverlayEditMode = .none) {
    self.padKind = padKind
    self.deviceId = deviceId
    self.irMode = irMode
    _editMode = State(initialValue: initialEditMode)
  }

  var body: some View {
    GeometryReader { geo in
      let bounds = CGRect(origin: .zero, size: geo.size)
      let orientation = TouchOverlayOrientation(isPortrait: geo.size.height >= geo.size.width)
      let layouts = TouchOverlayDefaults.layout(for: padKind, orientation: orientation)
      let opacity = TouchOverlayInput.resolvedOpacity(isEditing: editMode != .none, configuredOpacity: DOLConfigBridge.mainTouchPadOpacity())
      let variant = TouchOverlayArt.Style.current().resolvedVariant(padKind: padKind)
      // `revision` isn't read directly, but touching it here ties this body's re-evaluation to
      // every store mutation (position AND size-scale writes), matching phase 1's store contract.
      // NOTE: must stay a `let` declaration, not a bare `_ = ...` assignment — inside a
      // `@ViewBuilder` closure a bare assignment statement is itself treated as a View-producing
      // expression (type `()`, which doesn't conform to `View`) and fails to build.
      // swiftlint:disable:next redundant_discardable_let
      let _ = store.revision

      // The Wii IR surface (§2.1/§6.5) must paint FIRST (bottom of the ZStack): it's now a real,
      // resizable/movable box like any other group (task item 1), typically covering most of the
      // pad, so touches on a button/D-pad/stick drawn AFTER it need to be delivered to THOSE
      // controls first — the exclusion rule (§6.5) this ordering provides for free. Partition by
      // CONTROL KIND, not placement anchor: `.fillInset` (the IR pad's anchor) is a perfectly
      // normal resizable anchor now, so anchor alone no longer identifies "paint first" groups.
      let backgroundLayouts = layouts.filter(Self.isIRSurfaceLayout)
      let positionedLayouts = layouts.filter { !Self.isIRSurfaceLayout($0) }
      // Every OTHER group's resolved box (overlay coordinate space) — precomputed once so the IR
      // pad's exclusion rule can check "did this touch start inside another group" without each
      // group needing to recompute its siblings' boxes itself.
      let otherBoxes: [CGRect] = positionedLayouts.map {
        store.resolvedBox(for: $0, padKind: padKind, orientation: orientation, in: bounds)
      }

      ZStack {
        // Long-press-to-edit lives on a background layer BELOW every control surface, not on the
        // whole ZStack: attaching it to the container would let UIKit's ancestor gesture
        // recognizer cancel an in-progress touch on a button/D-pad/stick underneath it (its
        // default `cancelsTouchesInView` would force-release whatever was held), turning an
        // ordinary half-second button hold into an accidental edit-mode entry. A touch that lands
        // on a group's own surface is consumed there and never reaches this layer; only a touch on
        // genuinely empty overlay space does. On the Wii Remote pad this is reachable in the strip
        // outside the IR pad's default margin (`TouchOverlayDefaults.irPadMargin`) even though the
        // IR pad itself is now hit-testable — the Settings "Edit Layout…" entry (task item 3) is
        // the primary way in when the IR pad covers the whole screen after a resize.
        Color.clear
          .contentShape(Rectangle())
          .onLongPressGesture(minimumDuration: 0.5) {
            guard editMode == .none else { return }
            editMode = .layout
          }

        ForEach(backgroundLayouts, id: \.group) { layout in
          groupView(layout: layout, bounds: bounds, orientation: orientation, opacity: opacity,
                    variant: variant, excludedFrames: otherBoxes)
        }
        ForEach(positionedLayouts, id: \.group) { layout in
          groupView(layout: layout, bounds: bounds, orientation: orientation, opacity: opacity,
                    variant: variant, excludedFrames: [])
        }
        if editMode != .none {
          editToolbar
        }
      }
      .ignoresSafeArea()
    }
  }

  private static func isIRSurfaceLayout(_ layout: TouchOverlayGroupLayout) -> Bool {
    layout.controls.contains { if case .irSurface = $0.kind { return true }; return false }
  }

  // MARK: Per-group dispatch

  @ViewBuilder
  private func groupView(layout: TouchOverlayGroupLayout, bounds: CGRect, orientation: TouchOverlayOrientation,
                         opacity: Double, variant: TouchOverlayArt.Variant, excludedFrames: [CGRect]) -> some View {
    if layout.placement.anchor == .fill {
      // No group uses this anchor today (the Wii IR pad moved to `.fillInset`, §2.4/task item 1),
      // but it stays available: a whole-overlay, non-hit-testable, non-editable layer.
      content(for: layout, scale: 1.0, inputSuppressed: false, variant: variant, box: bounds, excludedFrames: [])
        .opacity(opacity)
        .frame(width: bounds.width, height: bounds.height)
        .position(x: bounds.midX, y: bounds.midY)
        .allowsHitTesting(false)
    } else {
      // Input is suppressed for EVERY group in EITHER edit mode, not just the group(s)
      // `showsChrome` makes editable (task item 1, design §9's mutual exclusion) — see
      // `PositionedTouchGroup`'s doc comment for why this used to be a single flag and why that
      // was wrong for `.irArea` mode specifically.
      let inputSuppressed = editMode.inputSuppressed
      let showsChrome = editMode.showsChrome(for: layout.group)
      let isIRPad = layout.group == .wiiIRPad
      let scale = store.sizeScale(for: layout.group, padKind: padKind, orientation: orientation)
      let box = store.resolvedBox(for: layout, padKind: padKind, orientation: orientation, in: bounds)
      PositionedTouchGroup(
        group: layout.group, box: box, bounds: bounds, inputSuppressed: inputSuppressed, showsChrome: showsChrome,
        onCommit: { resolved in
          store.setCenter(resolved, in: bounds, for: layout.group, padKind: padKind, orientation: orientation)
        },
        // `.layout` mode resizes every group (including `wiiIRPad`) UNIFORMLY, exactly as before
        // task item 1 — that's the "drag the corner handle" experience already shipped and
        // persisted, unaffected by the new independent-axis editor below.
        resize: editMode == .layout ? (scale: scale, onCommit: { newScale in
          let defaultCenter = layout.placement.center(in: bounds)
          store.setSizeScale(newScale, for: layout.group, padKind: padKind, orientation: orientation,
                             defaultCenter: TouchOverlayLayoutEngine.normalize(defaultCenter, in: bounds))
        }) : nil,
        // `.irArea` mode is ONLY ever entered for the Wii Remote pad kind's `wiiIRPad` group
        // (`TouchOverlayIRAreaEditorSheet` forces `padKind: .wiiRemote`), so this is the sole
        // group that ever gets `resizeAxes` — task item 1's independent width/height editor.
        resizeAxes: (editMode == .irArea && isIRPad) ? (scale: store.sizeScaleXY(for: layout.group, padKind: padKind, orientation: orientation),
                                                         onCommit: { newScaleXY in
          let defaultCenter = layout.placement.center(in: bounds)
          store.setIRSizeScale(newScaleXY, for: layout.group, padKind: padKind, orientation: orientation,
                               bounds: bounds, baseSize: layout.placement.resolvedSize(in: bounds),
                               defaultCenter: TouchOverlayLayoutEngine.normalize(defaultCenter, in: bounds))
        }) : nil,
        content: {
          content(for: layout, scale: scale, inputSuppressed: inputSuppressed, variant: variant, box: box, excludedFrames: excludedFrames)
            .opacity(opacity)
        }
      )
    }
  }

  @ViewBuilder
  private func content(for layout: TouchOverlayGroupLayout, scale: CGFloat, inputSuppressed: Bool,
                       variant: TouchOverlayArt.Variant, box: CGRect, excludedFrames: [CGRect]) -> some View {
    let groupSize = CGSize(width: layout.size.width * scale, height: layout.size.height * scale)
    if layout.controls.count == 1, case .dpad(let baseId) = layout.controls[0].kind {
      TouchOverlayDPadView(baseId: baseId, deviceId: deviceId, variant: variant, groupSize: groupSize, isEditing: inputSuppressed)
    } else if layout.controls.count == 1, case .stick(let baseId) = layout.controls[0].kind {
      TouchOverlayStickView(baseId: baseId, deviceId: deviceId, variant: variant, groupSize: groupSize, isEditing: inputSuppressed)
    } else if layout.controls.count == 1, case .irSurface = layout.controls[0].kind {
      // The exclusion boxes are in OVERLAY coordinates; the IR surface reports touches in its OWN
      // local space (origin at `box`'s top-left), so translate them into that space here.
      let localExcluded = excludedFrames.map { $0.offsetBy(dx: -box.minX, dy: -box.minY) }
      ZStack {
        // Render as a translucent region whenever ANY edit mode is active (task item 1) — during
        // normal play the surface is fully invisible but still live (its OWN `mode` gate, not
        // `inputSuppressed`, decides whether it processes touches).
        if inputSuppressed {
          TouchOverlayArt.irPad(variant: variant)
        }
        TouchOverlayIRPadView(mode: TCWiiTouchIRMode(rawValue: irMode) ?? .none, deviceId: deviceId,
                              excludedFrames: localExcluded, isEditing: inputSuppressed,
                              dragGain: TouchOverlayIRGeometry.clampDragGain(UserDefaults.standard.double(forKey: "touch_overlay_ir_pointer_gain")))
      }
    } else {
      TouchOverlayButtonClusterView(controls: layout.controls, deviceId: deviceId, variant: variant,
                                    groupSize: groupSize, scale: scale, isEditing: inputSuppressed)
    }
  }

  // MARK: Edit chrome

  private var editToolbar: some View {
    VStack {
      HStack {
        Spacer()
        HStack(spacing: 8) {
          Button {
            // The IR area editor's Reset only clears `wiiIRPad` (task item 1) — resetting the
            // WHOLE pad kind here would also silently discard the user's face-button/D-pad/stick
            // layout, which they weren't editing in this mode.
            switch editMode {
            case .irArea: store.resetGroup(.wiiIRPad, padKind: padKind)
            case .layout, .none: store.reset(padKind: padKind)
            }
          } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
          }
          .buttonStyle(.bordered)

          Button {
            editMode = .none
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
