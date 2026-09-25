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
  private let hapticGenerator = UIImpactFeedbackGenerator(style: .medium)

  private func scaledFrame(_ frame: CGRect) -> CGRect {
    CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
  }

  var body: some View {
    ZStack {
      ForEach(controls, id: \.id) { control in
        let frame = scaledFrame(control.frame)
        TouchOverlayArt.button(controlId: control.id, shape: shape(for: control), variant: variant,
                               pressed: pressed.contains(control.id))
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
          if down { hapticGenerator.impactOccurred() }
          switch control.kind {
          case .button(let raw):
            TCManagerInterface.setButtonStateFor(raw, controller: deviceId, state: down)
          case .axisButton(let raw):
            // Phase 2 simplification: binary 1.0/0.0, not force-sensitive. `TCButton` only takes
            // this path itself on a non-3D-Touch device; force-sensitive triggers are a phase 3
            // gap, not a regression (see the phase 2 plan doc).
            TCManagerInterface.setAxisValueFor(raw, controller: deviceId, value: down ? 1.0 : 0.0)
          case .stick, .dpad, .irSurface:
            break
          }
        },
        pressed: $pressed
      )
      .frame(width: groupSize.width, height: groupSize.height)
      .allowsHitTesting(!isEditing)
    }
    .onChange(of: isEditing) { _, editing in
      guard editing else { return }
      pressed = []
    }
  }

  private func shape(for control: TouchOverlayControl) -> TouchOverlayArt.ButtonShape {
    let suffix = control.id.split(separator: ".").last.map(String.init) ?? ""
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
  private let hapticGenerator = UIImpactFeedbackGenerator(style: .medium)

  var body: some View {
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
        hapticGenerator.impactOccurred()
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

  @State private var knobOffset: CGSize = .zero
  @State private var dragging = false

  private var maxDistance: CGFloat { groupSize.width * TouchOverlayInput.stickTravelFraction }

  var body: some View {
    let center = CGPoint(x: groupSize.width / 2, y: groupSize.height / 2)
    ZStack {
      TouchOverlayArt.stickBase(variant: variant, dragging: dragging)
      TouchOverlayArt.stickKnob(variant: variant)
        .frame(width: groupSize.width * 0.4, height: groupSize.height * 0.4)
        .offset(knobOffset)
      TouchOverlaySingleTouch { location in
        if let location {
          dragging = true
          let axes = TouchOverlayInput.stickAxes(touch: location, center: center, maxDistance: maxDistance)
          knobOffset = CGSize(width: axes.x * maxDistance, height: axes.y * maxDistance)
          send(x: axes.x, y: axes.y)
        } else {
          dragging = false
          knobOffset = .zero
          send(x: 0, y: 0)
        }
      }
      .allowsHitTesting(!isEditing)
    }
    .frame(width: groupSize.width, height: groupSize.height)
    .onChange(of: isEditing) { _, editing in
      guard editing else { return }
      dragging = false
      knobOffset = .zero
      send(x: 0, y: 0)
    }
  }

  private func send(x: CGFloat, y: CGFloat) {
    for write in TouchOverlayInput.stickWrites(x: x, y: y, baseId: baseId) {
      TCManagerInterface.setAxisValueFor(write.id, controller: deviceId, value: write.value)
    }
  }
}

/// The Wii IR drag/follow surface. Phase 2 renders it as an INERT translucent region only — no
/// touch handling, no writes (design §2.1: "at runtime it isn't a button"; phase 3 ports
/// `TCWiiPad.handleLongPress`/`sendIR` onto it). It must stay non-hit-testable: its box is the
/// WHOLE overlay (`.fill` anchor), so if it accepted touches it would swallow every other group's
/// input.
struct TouchOverlayIRPadView: View {
  let variant: TouchOverlayArt.Variant

  var body: some View {
    TouchOverlayArt.irPad(variant: variant)
      .allowsHitTesting(false)
  }
}
#endif
