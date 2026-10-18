// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import CoreGraphics
import UIKit

/// The haptics every touch control plays, one rule set for the Swift-drawn overlay, skins and the xib
/// pads:
/// - a button, shoulder, trigger, D-pad or skin action plays `.press` when it goes down, never while held
///   or on release;
/// - a stick plays `.stickTouchDown` when a finger lands on it, and `.stickRim` once when the knob reaches
///   the edge of its travel. Never one per move sample.
///
/// No in-app switch: `UIFeedbackGenerator` already plays nothing when System Haptics is off in iOS
/// Settings and on devices without a Taptic Engine.
enum TouchHapticEvent: Equatable {
  case press
  case stickTouchDown
  case stickRim
}

enum TouchHapticRules {
  /// Whether `now` holds something `previous` did not: a new button in a cluster, or the first direction
  /// of a D-pad (whose sets hold directions, so the caller checks `previous.isEmpty` instead).
  static func pressesSomethingNew<ID: Hashable>(previous: Set<ID>, now: Set<ID>) -> Bool {
    !now.isSubset(of: previous)
  }
}

/// A stick's haptic state over one touch. Pure, so the "touch-down, then the rim once" rule is testable.
struct StickHapticTracker {
  /// The knob counts as at the rim from here (axes are clamped to the unit circle)...
  static let rimEnter: CGFloat = 0.95
  /// ...and must come back inside this before the rim can play again, so a thumb resting on the edge
  /// doesn't buzz.
  static let rimExit: CGFloat = 0.8

  private var touching = false
  private var atRim = false

  /// `axes` is the stick's current deflection, nil when no finger is on it.
  mutating func update(axes: CGPoint?) -> TouchHapticEvent? {
    guard let axes else {
      touching = false
      atRim = false
      return nil
    }
    let magnitude = hypot(axes.x, axes.y)
    if !touching {
      touching = true
      // A touch that lands on the rim plays the touch-down only.
      atRim = magnitude >= Self.rimEnter
      return .stickTouchDown
    }
    if atRim {
      if magnitude < Self.rimExit { atRim = false }
      return nil
    }
    guard magnitude >= Self.rimEnter else { return nil }
    atRim = true
    return .stickRim
  }
}

/// One stick's tracker in a reference, so updating it on every move sample never invalidates SwiftUI.
@MainActor
final class TouchOverlayStickHaptics {
  private var tracker = StickHapticTracker()

  func update(axes: CGPoint?) {
    if let event = tracker.update(axes: axes) { TouchOverlayHaptics.play(event) }
  }
}

/// The generators, one per style for the app rather than one per control view struct (each parent
/// re-render would allocate a new one).
@MainActor
enum TouchOverlayHaptics {
  private static let press = UIImpactFeedbackGenerator(style: .medium)
  private static let stick = UIImpactFeedbackGenerator(style: .light)
  private static let rimIntensity: CGFloat = 0.5

  static func play(_ event: TouchHapticEvent) {
    switch event {
    case .press:
      press.impactOccurred()
    case .stickTouchDown:
      stick.impactOccurred()
      // Keeps the engine awake for this drag's rim tap.
      stick.prepare()
    case .stickRim:
      stick.impactOccurred(intensity: rimIntensity)
    }
  }
}
#endif
