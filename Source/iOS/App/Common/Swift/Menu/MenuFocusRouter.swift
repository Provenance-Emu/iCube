// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// D18: composes `MenuControllerNav` (raw input -> move/activate/back/
/// jumpSection edges) with a `MenuModel` (what ids exist and how they're
/// grouped) to produce focus transitions. Pure — no `GCController`, no
/// `ControllerFocusCoordinator`, no SwiftUI — so it is exercised directly by
/// scripted event sequences in tests (design doc §7 "Focus-order tests").
/// `MenuScreen` is a thin driver on top of this: it supplies the raw input
/// each tick and applies the returned `MenuFocusUpdate`.
struct MenuFocusRouter {
  private var nav: MenuControllerNav
  /// Per-pad state for the multi-pad `update(padInputs:...)` below. Kept
  /// entirely separate from `nav` (the single-pad path's state) so the
  /// existing single-pad API/tests are untouched by the multi-pad addition.
  private var navByPad: [AnyHashable: MenuControllerNav] = [:]
  private let config: MenuControllerNav.Config

  init(config: MenuControllerNav.Config = MenuControllerNav.Config()) {
    self.config = config
    nav = MenuControllerNav(config: config)
  }

  /// Advance one tick.
  ///
  /// - `isActive` mirrors `ControllerFocusCoordinator.isActiveScope(_:)` —
  ///   passed in rather than read from the coordinator so this stays a pure,
  ///   MainActor-free function tests can call directly. When `false` (another
  ///   `MenuScreen`/sheet currently owns the controller), the raw input is
  ///   still fed to the nav engine via `resync`, never dropped outright — a
  ///   plain early-return would leave `aLatched`/`bLatched` stuck at
  ///   whatever they were when ownership was lost, so a button still
  ///   physically held at the moment ownership returns would read as a
  ///   fresh press and fire a second, spurious activate/back (e.g. a double
  ///   pop when a covering sheet's own B dismissed it). Resyncing every
  ///   inactive tick keeps the latches tracking the physical state
  ///   throughout, so reactivation only ever sees a genuinely new edge.
  mutating func update(
    _ input: MenuControllerNav.Input,
    at time: TimeInterval,
    model: MenuModel,
    focusedID: String?,
    isActive: Bool
  ) -> MenuFocusUpdate {
    guard isActive else {
      nav.resync(input, at: time)
      return MenuFocusUpdate(focusedID: focusedID)
    }
    return MenuFocusRouter.apply(nav.update(input, at: time), model: model, focusedID: focusedID)
  }

  /// Multi-pad variant (D18 gap: "MenuScreen listens only to the first
  /// connected extended gamepad"). One `MenuControllerNav` per pad, keyed by
  /// caller-supplied identity (`MenuScreen` uses `ObjectIdentifier(GCController)`;
  /// tests use plain strings) -- mirrors `PauseMenuView.pauseNavGates`'s
  /// `[ObjectIdentifier: PauseMenuInputGate]` keying, for the same reason: a
  /// single shared latch would let one pad's button-up clear or set another
  /// pad's latch, and OR-ing raw booleans together before edge-detection can
  /// never register a fresh press from pad B while pad A is still holding
  /// the same button down.
  ///
  /// Events from every connected pad drain into ONE focus timeline in
  /// `padInputs` order: each pad's own edges apply against whatever
  /// `focusedID` the previous pad's events already produced this tick, so a
  /// pad that only moves and a pad that only activates combine correctly
  /// without either pad's input being dropped. At most one `.activate` (and
  /// one `.back`) is honoured per tick -- the first pad to report a fresh
  /// edge wins -- so two pads independently pressing A in the same tick
  /// still yields exactly one activation, not two.
  ///
  /// A pad seen for the first time (this screen's very first tick, or a
  /// controller that connects mid-session) is `resync`ed instead of
  /// `update`d, exactly like the single-pad `resync(_:at:)` this composes:
  /// otherwise a pad that is already holding A the instant it is first
  /// observed would read as a fresh press-edge and fire a phantom activate.
  mutating func update(
    padInputs: [(AnyHashable, MenuControllerNav.Input)],
    at time: TimeInterval,
    model: MenuModel,
    focusedID: String?,
    isActive: Bool
  ) -> MenuFocusUpdate {
    let connected = Set(padInputs.map(\.0))
    navByPad = navByPad.filter { connected.contains($0.key) }

    var current = focusedID
    var activated: String?
    var didGoBack = false

    for (padID, input) in padInputs {
      let isNewPad = navByPad[padID] == nil
      var padNav = navByPad[padID] ?? MenuControllerNav(config: config)
      guard isActive, !isNewPad else {
        padNav.resync(input, at: time)
        navByPad[padID] = padNav
        continue
      }
      let events = padNav.update(input, at: time)
      navByPad[padID] = padNav
      let padResult = MenuFocusRouter.apply(events, model: model, focusedID: current)
      current = padResult.focusedID
      if activated == nil { activated = padResult.activatedID }
      if padResult.didGoBack { didGoBack = true }
    }
    return MenuFocusUpdate(focusedID: current, activatedID: activated, didGoBack: didGoBack)
  }

  /// Adopt the current physical input without emitting anything. `MenuScreen`
  /// calls this once, instead of `update`, on the very first tick after the
  /// screen appears — the button that *opened* this screen (e.g. A on a
  /// `.navigation` item in the parent) is still physically held on that
  /// first tick, and if focus already defaults to the first item (unlike
  /// `RemapPlayerView`, which starts with no highlight), an `update` call
  /// there would immediately activate it a second time. `resync` lets the
  /// nav engine observe that the button is down without treating it as a
  /// new press, so only a release-then-press after the screen is genuinely
  /// interactive counts.
  mutating func resync(_ input: MenuControllerNav.Input, at time: TimeInterval) {
    nav.resync(input, at: time)
  }

  /// Shared event-application core for both the single-pad `update` above
  /// and the multi-pad `update(padInputs:...)` -- kept as one function so
  /// the two paths cannot silently drift apart.
  private static func apply(_ events: [MenuControllerNav.Event], model: MenuModel, focusedID: String?) -> MenuFocusUpdate {
    var current = focusedID
    var activated: String?
    var didGoBack = false
    for event in events {
      switch event {
      case .move(let step):
        current = MenuFocusRouter.move(current, by: step, in: model)
      case .jumpSection(let step):
        if let existing = current, let jumped = model.firstFocusableID(sectionOffsetFrom: existing, by: step) {
          current = jumped
        } else if current == nil {
          current = model.focusableIDs.first
        }
      case .activate:
        if let current { activated = current }
      case .back:
        didGoBack = true
      }
    }
    return MenuFocusUpdate(focusedID: current, activatedID: activated, didGoBack: didGoBack)
  }

  /// Move within the flat focusable order, clamped — no wraparound (matches
  /// the pause menu's existing `movePauseFocus` behaviour).
  static func move(_ focusedID: String?, by step: Int, in model: MenuModel) -> String? {
    let order = model.focusableIDs
    guard !order.isEmpty else { return nil }
    guard let current = focusedID, let index = order.firstIndex(of: current) else {
      return order.first
    }
    return order[max(0, min(order.count - 1, index + step))]
  }

  /// Reconciles a live `focusedID` against a freshly rebuilt `model`.
  ///
  /// `MenuItem.id` is stable, so most rebuilds (a toggle flips, a badge
  /// count changes) leave `focusedID` valid as-is. But an item can still
  /// disappear from under a live focus (the last cheat is deleted, a
  /// platform-conditional row goes away) — falling back to the first item
  /// every time would be jarring for a small list change, so this instead
  /// prefers whatever item now sits at the same flat index the vanished one
  /// used to occupy (from `previousOrder`, captured before the rebuild),
  /// clamped to the new order, and only falls back to the first item when
  /// even that can't be resolved (e.g. `focusedID` was never in
  /// `previousOrder` either).
  static func reconcile(focusedID: String?, previousOrder: [String], model: MenuModel) -> String? {
    let order = model.focusableIDs
    guard !order.isEmpty else { return nil }
    guard let focusedID else { return order.first }
    if order.contains(focusedID) { return focusedID }
    if let oldIndex = previousOrder.firstIndex(of: focusedID) {
      return order[min(oldIndex, order.count - 1)]
    }
    return order.first
  }
}

/// Result of one `MenuFocusRouter.update` tick.
struct MenuFocusUpdate: Equatable {
  var focusedID: String?
  /// Set exactly when an activate edge fired on a currently-focused item.
  var activatedID: String?
  var didGoBack = false
}
