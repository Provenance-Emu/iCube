// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI
import UIKit

/// The programmatic touch overlay's SwiftUI root (design §3/§4/§8 phase 2, IR wiring + settings
/// phase 3), behind the `touch_overlay_programmatic` flag. `GeometryReader` + `ZStack` of one
/// `PositionedTouchGroup` per `TouchOverlayDefaults.layout(for:orientation:canvas:safeArea:)` entry — a port of
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

  /// The space the editor's drags are measured in (`PositionedTouchGroup`): the whole overlay, which
  /// does not move while a group does.
  static let coordinateSpace = NamedCoordinateSpace.named("TouchOverlayView")

  @ObservedObject private var store: TouchOverlayLayoutStore
  @State private var editMode: TouchOverlayEditMode
  /// Set only by the DEBUG layout gallery: the safe area of the device being simulated. Live
  /// overlays read the real one from the window.
  private let previewSafeArea: UIEdgeInsets?
  /// What Done does in a host that exists only to edit (`TouchOverlayLayoutEditorView`): it closes
  /// that host. nil returns the overlay to play in place.
  private let onDone: (() -> Void)?
  /// Drawn at the start of the edit toolbar (the editor's pad picker).
  private let toolbarAccessory: AnyView?

  /// - Parameter initialEditMode: opens straight into an edit mode, for
  ///   `TouchOverlayLayoutEditorView` ("Edit Layout…" / "Edit IR Area…") — it has no live
  ///   device context, so every group's input is suppressed from the first frame
  ///   (`TouchOverlayEditMode.inputSuppressed`), and no `TCManagerInterface` write can happen
  ///   regardless of the placeholder `deviceId` it passes. It also passes
  ///   `irMode: .gyro` so the IR pad's `mode`/`isEditingFlag` transition on mount
  ///   can't send a stray "recenter" write either (see `TouchOverlayIRPadView`'s doc comment).
  /// - Parameter store: the gallery passes an empty in-memory store so it always shows defaults.
  init(padKind: TouchOverlayPadKind, deviceId: Int, irMode: Int, initialEditMode: TouchOverlayEditMode = .none,
       store: TouchOverlayLayoutStore = .shared, previewSafeArea: UIEdgeInsets? = nil,
       onDone: (() -> Void)? = nil, toolbarAccessory: AnyView? = nil) {
    self.padKind = padKind
    self.deviceId = deviceId
    self.irMode = irMode
    _editMode = State(initialValue: initialEditMode)
    _store = ObservedObject(wrappedValue: store)
    self.previewSafeArea = previewSafeArea
    self.onDone = onDone
    self.toolbarAccessory = toolbarAccessory
  }

  var body: some View {
    GeometryReader { geo in
      // The host lays this view out inside the safe area; the overlay itself draws edge to edge
      // (the offset below), so lay out on the whole screen and keep controls out of the inset edges.
      let geometry = TouchOverlayCanvas(hostSize: geo.size, hostInsets: UIEdgeInsets(geo.safeAreaInsets),
                                        previewSafeArea: previewSafeArea)
      let canvas = geometry.size
      let safeArea = geometry.safeArea
      let bounds = geometry.bounds
      let orientation = geometry.orientation
      let layouts = TouchOverlayDefaults.layout(for: padKind, orientation: orientation, canvas: canvas, safeArea: safeArea)
      let opacity = TouchOverlayInput.resolvedOpacity(isEditing: editMode != .none, configuredOpacity: DOLConfigBridge.mainTouchPadOpacity())
      let variant = TouchOverlayArt.variant(for: padKind)
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
        // IR pad itself is now hit-testable — the Controllers hub's "Edit Layout…" entry is the
        // primary way in when the IR pad covers the whole screen after a resize.
        // The game screen owns layout editing: it closes its bar and edits on this same canvas
        // above everything, so ask it instead of editing in place underneath its top strip.
        Color.clear
          .contentShape(Rectangle())
          .onLongPressGesture(minimumDuration: 0.5) {
            guard editMode == .none else { return }
            NotificationCenter.default.post(name: .DOLEditTouchLayout, object: nil)
          }

        if editMode != .none {
          safeAreaGuide(bounds: bounds, safeArea: safeArea)
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
          editToolbar(safeArea: safeArea)
        }
      }
      .coordinateSpace(Self.coordinateSpace)
      // Pin the full-size canvas to the screen's corner explicitly rather than relying on how
      // `.ignoresSafeArea()` positions an explicitly sized frame.
      .frame(width: canvas.width, height: canvas.height)
      .offset(x: -geometry.hostOrigin.x, y: -geometry.hostOrigin.y)
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
        // (Edit IR Area… opens the editor with `padKind: .wiiRemote`), so this is the sole
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
        TouchOverlayIRPadView(mode: TCWiiTouchIRMode(rawValue: irMode) ?? .gyro, deviceId: deviceId,
                              excludedFrames: localExcluded, isEditing: inputSuppressed,
                              dragGain: TouchOverlayIRGeometry.clampDragGain(MotionSettings.irPointerGain()))
      }
    } else {
      TouchOverlayButtonClusterView(controls: layout.controls, deviceId: deviceId, variant: variant,
                                    groupSize: groupSize, scale: scale, isEditing: inputSuppressed)
    }
  }

  // MARK: Edit chrome

  /// The safe area's edges, drawn faintly while editing. Every editor clamps groups to the whole
  /// canvas (the defaults stay inside the safe area on their own), so this shows where the rounded
  /// corners and the sensor housing begin, and that a group stopping past it is at the screen edge.
  private func safeAreaGuide(bounds: CGRect, safeArea: UIEdgeInsets) -> some View {
    let safe = bounds.inset(by: safeArea)
    return Rectangle()
      .stroke(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
      .frame(width: safe.width, height: safe.height)
      .position(x: safe.midX, y: safe.midY)
      .allowsHitTesting(false)
  }

  /// Top centre, inside the safe area: clear of the top corners, where the shoulder buttons sit, and of
  /// the bottom edge every default hangs from. It used to sit top right, which in landscape (no top
  /// inset) was under the game screen's 80 pt reveal strip, so Done revealed the top bar instead. The
  /// editor now covers that strip and the bar, and this keeps it clear of the controls too.
  private func editToolbar(safeArea: UIEdgeInsets) -> some View {
    VStack {
      HStack {
        Spacer()
        HStack(spacing: 8) {
          if let toolbarAccessory {
            toolbarAccessory
          }
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
            if let onDone {
              onDone()
            } else {
              editMode = .none
            }
          } label: {
            Label("Done", systemImage: "checkmark")
          }
          .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding()
        Spacer()
      }
      Spacer()
    }
    .padding(EdgeInsets(top: safeArea.top, leading: safeArea.left, bottom: safeArea.bottom, trailing: safeArea.right))
  }
}
#endif

#if os(iOS)
/// The rectangle the overlay lays out on, from what its `GeometryReader` reports. Every host lays the
/// overlay out inside the safe area (the game's `TouchPadsContainer`, the full-screen layout editor)
/// and the canvas adds the insets back, so it is the whole screen in each of them; the DEBUG gallery
/// hosts edge to edge and passes the simulated device's insets instead. Positions are stored as
/// fractions of `bounds` and sizes scale with it, so the hosts must agree on it: the layout editor
/// used to sit under a navigation bar and a picker, and everything placed there moved in the game.
struct TouchOverlayCanvas: Equatable {
  let size: CGSize
  let safeArea: UIEdgeInsets
  /// Where the host's origin sits on the canvas: the leading and top insets it was laid out inside.
  let hostOrigin: CGPoint

  init(hostSize: CGSize, hostInsets: UIEdgeInsets, previewSafeArea: UIEdgeInsets? = nil) {
    let live = previewSafeArea == nil ? hostInsets : .zero
    size = CGSize(width: hostSize.width + live.left + live.right, height: hostSize.height + live.top + live.bottom)
    safeArea = previewSafeArea ?? live
    hostOrigin = CGPoint(x: live.left, y: live.top)
  }

  var bounds: CGRect { CGRect(origin: .zero, size: size) }
  var orientation: TouchOverlayOrientation { TouchOverlayOrientation(isPortrait: size.height >= size.width) }
}

private extension UIEdgeInsets {
  init(_ insets: EdgeInsets) {
    self.init(top: insets.top, left: insets.leading, bottom: insets.bottom, right: insets.trailing)
  }
}
#endif
