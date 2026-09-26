// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// D18 (`docs/superpowers/specs/2026-09-24-data-driven-menus-design.md`) engine:
/// iOS-only controller navigation for `MenuScreen`. This is the button-remap
/// screen's `RemapControllerNav` moved here verbatim (behaviour unchanged,
/// `RemapModel.swift` now aliases `RemapControllerNav` to this type) plus the
/// shoulder/section-jump addition the design doc's §2 asks for. Nothing here
/// touches GameController, SwiftUI or `ControllerFocusCoordinator` — it is a
/// pure state machine so `MenuFocusRouter`'s tests (and `RemapModelTests`,
/// which still exercise it under the old name) never need a real controller.
///
/// - Move is edge-triggered with hold-to-repeat: one step on the press edge,
///   nothing for `initialRepeatDelay`, then a step every `repeatInterval`.
///   The stick has hysteresis: it must fall back inside `stickRelease` before
///   a new push past `stickEngage` counts as a new edge.
/// - A, B and both shoulders are latch-and-rearm: one event per physical
///   press, re-armed only once the button reports released — the
///   GameController framework can call `valueChangedHandler` more than once
///   per press, and polling sees a held button on every tick.
struct MenuControllerNav: Equatable {
  struct Config: Equatable {
    var initialRepeatDelay: TimeInterval = 0.4
    var repeatInterval: TimeInterval = 0.08
    var stickEngage: Float = 0.6
    var stickRelease: Float = 0.3
  }

  struct Input: Equatable {
    var up = false
    var down = false
    /// Left stick Y, +1 is up.
    var stickY: Float = 0
    var a = false
    var b = false
    /// L1 — jumps to the first focusable item of the previous `MenuSection`.
    var leftShoulder = false
    /// R1 — jumps to the first focusable item of the next `MenuSection`.
    var rightShoulder = false
  }

  enum Event: Equatable {
    /// -1 = up one row, +1 = down one row.
    case move(Int)
    case activate
    case back
    /// -1 = previous section, +1 = next section.
    case jumpSection(Int)
  }

  let config: Config
  private var heldDirection = 0
  private var holdStart: TimeInterval = 0
  private var lastRepeat: TimeInterval = 0
  private var stickEngaged = false
  private var aLatched = false
  private var bLatched = false
  private var leftShoulderLatched = false
  private var rightShoulderLatched = false
  /// Set by `resync`: the current hold produces no repeats until released.
  private var suppressRepeatUntilRelease = false

  init(config: Config = Config()) {
    self.config = config
  }

  mutating func update(_ input: Input, at time: TimeInterval) -> [Event] {
    var events: [Event] = []
    let direction = resolveDirection(input)
    if direction != heldDirection {
      heldDirection = direction
      suppressRepeatUntilRelease = false
      if direction != 0 {
        holdStart = time
        lastRepeat = time
        events.append(.move(direction))
      }
    } else if direction != 0, !suppressRepeatUntilRelease,
              time - holdStart >= config.initialRepeatDelay,
              time - lastRepeat >= config.repeatInterval {
      lastRepeat = time
      events.append(.move(direction))
    }

    if input.a {
      if !aLatched {
        aLatched = true
        events.append(.activate)
      }
    } else {
      aLatched = false
    }

    if input.b {
      if !bLatched {
        bLatched = true
        events.append(.back)
      }
    } else {
      bLatched = false
    }

    if input.leftShoulder {
      if !leftShoulderLatched {
        leftShoulderLatched = true
        events.append(.jumpSection(-1))
      }
    } else {
      leftShoulderLatched = false
    }

    if input.rightShoulder {
      if !rightShoulderLatched {
        rightShoulderLatched = true
        events.append(.jumpSection(1))
      }
    } else {
      rightShoulderLatched = false
    }

    return events
  }

  /// Adopt the current physical state without emitting anything.
  ///
  /// Two call sites need this, both to avoid a stale-press misfire:
  /// - A capture/child-screen session ends while a button/stick push that
  ///   triggered it is still held; the next real `update` must not read that
  ///   hold as a fresh "activate" or "move" edge.
  /// - `MenuFocusRouter` calls this every tick a screen's input is *not*
  ///   active (`ControllerFocusCoordinator` says another surface owns the
  ///   controller) instead of skipping the tick outright. Skipping would
  ///   leave `aLatched`/`bLatched` stuck at whatever they were when the
  ///   screen lost ownership; if the button that dismissed the covering
  ///   surface is still physically held when ownership returns, an
  ///   `update` call would see `false -> true` on `b` and fire a second,
  ///   spurious `.back` — a double pop. Resyncing every inactive tick keeps
  ///   the latches tracking the physical state throughout, so reactivation
  ///   only ever sees a real new edge.
  mutating func resync(_ input: Input, at time: TimeInterval) {
    heldDirection = resolveDirection(input)
    holdStart = time
    lastRepeat = time
    suppressRepeatUntilRelease = heldDirection != 0
    aLatched = input.a
    bLatched = input.b
    leftShoulderLatched = input.leftShoulder
    rightShoulderLatched = input.rightShoulder
  }

  private mutating func resolveDirection(_ input: Input) -> Int {
    if input.up != input.down {
      return input.up ? -1 : 1
    }
    let magnitude = abs(input.stickY)
    if stickEngaged {
      if magnitude < config.stickRelease { stickEngaged = false }
    } else if magnitude > config.stickEngage {
      stickEngaged = true
    }
    guard stickEngaged else { return 0 }
    return input.stickY > 0 ? -1 : 1
  }
}
