// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI
import UIKit

/// The four content views a `TouchOverlayGroupLayout` can render as (dispatched by
/// `TouchOverlayView`), each writing ONLY through `TCManagerInterface` (design §6.1) with the
/// caller-supplied `deviceId` (the Touchscreen device id, never the player slot — §6.3).

/// A cluster of one or more button / axis-button controls sharing ONE touch surface (e.g. GC's
/// B/A/Y/X face buttons, or a single button living alone in its own group). Backing store for
/// `TouchOverlayCluster` is the control's own `id` string.
struct TouchOverlayButtonClusterView: View {
  let controls: [TouchOverlayControl]
  let deviceId: Int
  let variant: TouchOverlayArt.Variant
  /// The group's RESOLVED (already scaled by any stored size, §2.4) box size.
  let groupSize: CGSize
  /// `groupSize.width / layout.size.width` — scales each control's default-authored local frame
  /// (in `TouchOverlayDefaults`' unscaled coordinates) up/down along with the group itself, so a
  /// resized group's buttons and hit regions grow together instead of drifting apart.
  let scale: CGFloat
  /// Set true while the layout editor is active: input is suppressed and anything already held
  /// is force-released (§4 — a control must not stay down across the edit-mode transition).
  let isEditing: Bool

  @State private var pressed: Set<String> = []

  private func scaledFrame(_ frame: CGRect) -> CGRect {
    CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
  }

  /// Axis-button control ids in this cluster (task item 2, phase 3): these report continuous
  /// touch-force via `TouchOverlayCluster.onForce` instead of the binary press/release
  /// `TouchOverlayInput`/`onChange` alone provides.
  private var axisButtonIds: Set<String> {
    Set(controls.compactMap { control in
      if case .axisButton = control.kind { return control.id }
      return nil
    })
  }

  var body: some View {
    // swiftlint:disable:next redundant_discardable_let
    let _ = TouchOverlayRenderProbe.body(.buttonCluster)
    ZStack {
      ForEach(controls, id: \.id) { control in
        let frame = scaledFrame(control.frame)
        // Equatable, so a press re-renders only the button whose state changed, not its neighbours.
        TouchOverlayButtonArtView(controlId: control.id, shape: shape(for: control), variant: variant,
                                  pressed: pressed.contains(control.id))
          .equatable()
          .frame(width: frame.width, height: frame.height)
          .position(x: frame.midX, y: frame.midY)
      }
      TouchOverlayCluster<String>(
        hitTest: { location, _ in
          let regions = controls.map { TouchOverlayHitTester.Region(id: $0.id, frame: scaledFrame($0.frame)) }
          return TouchOverlayHitTester.union(touches: [location], regions: regions)
        },
        onChange: { id, down in
          guard let control = controls.first(where: { $0.id == id }) else { return }
          if down { TouchOverlayHaptics.impact() }
          switch control.kind {
          case .button(let raw):
            TCManagerInterface.setButtonStateFor(raw, controller: deviceId, state: down)
          case .axisButton(let raw):
            // RELEASE only. The press write is `TouchOverlayCluster.recompute`'s job now (task
            // item 2's DSU pass): this control's id is always a member of `pressureIds` (see
            // `axisButtonIds` below), so `onForce` — which runs in the SAME `recompute()` pass,
            // right after the press/release transitions this closure reacts to — is guaranteed to
            // supply the initial value (real pressure, or its own 1.0 fallback for a multi-touch
            // ambiguity or non-force hardware). Writing a synthetic 1.0 here too raced `onForce`'s
            // real sample within that same pass and produced a spurious full-press-then-release
            // blip on the DSU-mirrored shoulder button for any force-reporting touch.
            if !down {
              TCManagerInterface.setAxisValueFor(raw, controller: deviceId, value: 0.0)
            }
          case .stick, .dpad, .irSurface:
            break
          }
        },
        pressed: $pressed,
        pressureIds: axisButtonIds,
        onForce: { id, pressure in
          guard let control = controls.first(where: { $0.id == id }), case .axisButton(let raw) = control.kind else { return }
          TCManagerInterface.setAxisValueFor(raw, controller: deviceId, value: pressure)
        }
      )
      .frame(width: groupSize.width, height: groupSize.height)
      .allowsHitTesting(!isEditing)
    }
    .onChange(of: isEditing) { _, editing in
      guard editing else { return }
      // Release every currently-held control's write BEFORE clearing `pressed` (task item 2's DSU
      // pass): `pressed` is a plain `@State` bound into `TouchOverlayCluster` below, so just
      // setting it to `[]` here only resets the SwiftUI highlight — it does NOT retrigger the
      // cluster's `onChange` callback (that only fires from `recompute()`, driven by touch events,
      // never by an external write to the binding), so the actual `TCManagerInterface` release
      // this loop performs would otherwise never happen. A button held when the user long-presses
      // into edit mode was left "down" in `StateManager` (and its DSU mirror) for as long as the
      // editor stayed open.
      for id in pressed {
        guard let control = controls.first(where: { $0.id == id }) else { continue }
        switch control.kind {
        case .button(let raw): TCManagerInterface.setButtonStateFor(raw, controller: deviceId, state: false)
        case .axisButton(let raw): TCManagerInterface.setAxisValueFor(raw, controller: deviceId, value: 0.0)
        case .stick, .dpad, .irSurface: break
        }
      }
      pressed = []
    }
  }

  private func shape(for control: TouchOverlayControl) -> TouchOverlayArt.ButtonShape {
    let suffix = control.id.split(separator: ".").last.map(String.init) ?? ""
    // Only the GameCube's X and Y are kidney-shaped; the Classic Controller's are round.
    if control.id.hasPrefix("classic."), suffix == "x" || suffix == "y" { return .circle }
    switch suffix {
    case "a", "b", "one", "two", "c": return .circle
    case "x", "y": return .kidney
    case "z", "l", "r", "zl", "zr": return .bar
    case "start", "minus", "plus", "home": return .pill
    default: return .circle
    }
  }
}

/// The D-pad: one shared touch surface bucketing every live touch into up/down/left/right (8-way,
/// with diagonals) via `TouchOverlayHitTester.dpadDirections`, writing all four button states on
/// every change — matching `TCDirectionalPad`, which always resends all four rather than a delta
/// per direction. Haptic fires once on the empty -> non-empty transition only (also matching
/// `TCDirectionalPad`'s `isPressed` gate), never per-direction while already held.
struct TouchOverlayDPadView: View {
  let baseId: Int
  let deviceId: Int
  let variant: TouchOverlayArt.Variant
  let groupSize: CGSize
  let isEditing: Bool

  @State private var pressed: Set<TouchOverlayHitTester.DPadDirection> = []

  var body: some View {
    // swiftlint:disable:next redundant_discardable_let
    let _ = TouchOverlayRenderProbe.body(.dpad)
    ZStack {
      TouchOverlayArt.dpad(pressed: pressed, variant: variant)
      TouchOverlayCluster<TouchOverlayHitTester.DPadDirection>(
        hitTest: { location, size in
          TouchOverlayHitTester.dpadDirections(at: location, in: size, previous: pressed)
        },
        onChange: { _, _ in
          // The per-direction transition is intentionally a no-op here: the D-pad sends its
          // whole state together (see `onChange(of: pressed)` below), matching `TCDirectionalPad`.
        },
        pressed: $pressed
      )
      .allowsHitTesting(!isEditing)
    }
    .frame(width: groupSize.width, height: groupSize.height)
    .onChange(of: pressed) { oldValue, newValue in
      let writes = TouchOverlayInput.dpadWrites(up: newValue.contains(.up), down: newValue.contains(.down),
                                                left: newValue.contains(.left), right: newValue.contains(.right),
                                                baseId: baseId)
      for write in writes {
        TCManagerInterface.setButtonStateFor(write.id, controller: deviceId, state: write.pressed)
      }
      if oldValue.isEmpty, !newValue.isEmpty {
        TouchOverlayHaptics.impact()
      }
    }
    .onChange(of: isEditing) { _, editing in
      guard editing else { return }
      pressed = []
    }
  }
}

/// The analog stick: a single-touch tracker (design §3, §6.4) whose knob follows the finger and
/// writes the four half-axis values through `TouchOverlayInput.stickWrites` — bit-for-bit the
/// `TCJoystick` convention, which must NOT be "cleaned up" to match the IR/IMU conventions
/// (§6.4). No haptics: `TCJoystick` has none, and firing one on every move sample would be exactly
/// the per-move-sample cost §3 warns against.
struct TouchOverlayStickView: View {
  let baseId: Int
  let deviceId: Int
  let variant: TouchOverlayArt.Variant
  let groupSize: CGSize
  let isEditing: Bool

  /// The knob's offset lives in a reference the parent never reads, so a move sample re-renders only
  /// the knob (`TouchOverlayStickKnobView`), never the base or this container.
  @State private var knob = TouchOverlayKnobPosition()
  /// Changes only when a drag starts or ends: it lights the base's rim.
  @State private var dragging = false

  private var maxDistance: CGFloat { groupSize.width * TouchOverlayInput.stickTravelFraction }

  var body: some View {
    // swiftlint:disable:next redundant_discardable_let
    let _ = TouchOverlayRenderProbe.body(.stick)
    let center = CGPoint(x: groupSize.width / 2, y: groupSize.height / 2)
    ZStack {
      TouchOverlayStickBaseView(variant: variant, dragging: dragging)
        .equatable()
      TouchOverlayStickKnobView(variant: variant, size: CGSize(width: groupSize.width * 0.4, height: groupSize.height * 0.4),
                                position: knob)
      TouchOverlaySingleTouch { location in
        if let location {
          if !dragging { dragging = true }
          let axes = TouchOverlayInput.stickAxes(touch: location, center: center, maxDistance: maxDistance)
          knob.offset = CGSize(width: axes.x * maxDistance, height: axes.y * maxDistance)
          send(x: axes.x, y: axes.y)
        } else {
          if dragging { dragging = false }
          knob.offset = .zero
          send(x: 0, y: 0)
        }
      }
      .allowsHitTesting(!isEditing)
    }
    .frame(width: groupSize.width, height: groupSize.height)
    .onChange(of: isEditing) { _, editing in
      guard editing else { return }
      dragging = false
      knob.offset = .zero
      send(x: 0, y: 0)
    }
  }

  private func send(x: CGFloat, y: CGFloat) {
    for write in TouchOverlayInput.stickWrites(x: x, y: y, baseId: baseId) {
      TCManagerInterface.setAxisValueFor(write.id, controller: deviceId, value: write.value)
    }
  }
}

/// Where a stick's knob sits. Observable per property: only a view that reads `offset` in its body
/// (the knob) is invalidated when it changes.
@Observable
final class TouchOverlayKnobPosition {
  var offset: CGSize = .zero
}

/// The stick's static base, re-rendered only when a drag starts or ends.
struct TouchOverlayStickBaseView: View, Equatable {
  let variant: TouchOverlayArt.Variant
  let dragging: Bool

  var body: some View {
    // swiftlint:disable:next redundant_discardable_let
    let _ = TouchOverlayRenderProbe.body(.stickBase)
    TouchOverlayArt.stickBase(variant: variant, dragging: dragging)
  }
}

/// The knob, the one part of a stick that changes on every move sample. Its art is a separate
/// equatable view, so a move only re-applies the offset rather than rebuilding the gradient and shadow.
struct TouchOverlayStickKnobView: View {
  let variant: TouchOverlayArt.Variant
  let size: CGSize
  let position: TouchOverlayKnobPosition

  var body: some View {
    // swiftlint:disable:next redundant_discardable_let
    let _ = TouchOverlayRenderProbe.body(.stickKnob)
    TouchOverlayKnobArtView(variant: variant)
      .equatable()
      .frame(width: size.width, height: size.height)
      .offset(position.offset)
  }
}

private struct TouchOverlayKnobArtView: View, Equatable {
  let variant: TouchOverlayArt.Variant

  var body: some View {
    TouchOverlayArt.stickKnob(variant: variant)
  }
}

/// One button's art, equatable on everything it draws from.
struct TouchOverlayButtonArtView: View, Equatable {
  let controlId: String
  let shape: TouchOverlayArt.ButtonShape
  let variant: TouchOverlayArt.Variant
  let pressed: Bool

  var body: some View {
    TouchOverlayArt.button(controlId: controlId, shape: shape, variant: variant, pressed: pressed)
  }
}

/// The overlay's press haptic. One generator for the app, rather than a new
/// `UIImpactFeedbackGenerator` allocated with every control view struct (each parent re-render).
@MainActor
enum TouchOverlayHaptics {
  private static let generator = UIImpactFeedbackGenerator(style: .medium)

  static func impact() {
    generator.impactOccurred()
  }
}
#endif
