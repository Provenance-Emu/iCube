// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreGraphics
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
  /// The row a left/right press edge landed on, so a hold repeats only on that row: a hold that began
  /// elsewhere and slid onto a stepper needs a fresh press. One per pad for the multi-pad path.
  private var adjustOrigin: String?
  private var adjustOriginByPad: [AnyHashable: String] = [:]

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
    isActive: Bool,
    columns: Int = 1,
    stepsPickersInGrid: Bool = true
  ) -> MenuFocusUpdate {
    guard isActive else {
      nav.resync(input, at: time)
      return MenuFocusUpdate(focusedID: focusedID)
    }
    return MenuFocusRouter.apply(
      nav.update(input, at: time), model: model, focusedID: focusedID, columns: columns, stepsPickersInGrid: stepsPickersInGrid,
      adjustOrigin: &adjustOrigin)
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
  ///
  /// `columns` is the grid's column count for `MenuStyle.grid` (see `apply`); a list passes 1.
  mutating func update(
    padInputs: [(AnyHashable, MenuControllerNav.Input)],
    at time: TimeInterval,
    model: MenuModel,
    focusedID: String?,
    isActive: Bool,
    columns: Int = 1,
    stepsPickersInGrid: Bool = true
  ) -> MenuFocusUpdate {
    let connected = Set(padInputs.map(\.0))
    navByPad = navByPad.filter { connected.contains($0.key) }
    adjustOriginByPad = adjustOriginByPad.filter { connected.contains($0.key) }

    var current = focusedID
    var activated: String?
    var longActivated: String?
    var didGoBack = false
    var adjust: (id: String, step: Int)?

    for (padID, input) in padInputs {
      let isNewPad = navByPad[padID] == nil
      var padNav = navByPad[padID] ?? MenuControllerNav(config: config)
      guard isActive, !isNewPad else {
        padNav.resync(input, at: time)
        navByPad[padID] = padNav
        adjustOriginByPad[padID] = nil
        continue
      }
      let events = padNav.update(input, at: time)
      navByPad[padID] = padNav
      var origin = adjustOriginByPad[padID]
      let padResult = MenuFocusRouter.apply(
        events, model: model, focusedID: current, columns: columns, stepsPickersInGrid: stepsPickersInGrid, adjustOrigin: &origin)
      adjustOriginByPad[padID] = origin
      current = padResult.focusedID
      if activated == nil { activated = padResult.activatedID }
      if longActivated == nil { longActivated = padResult.longActivatedID }
      if adjust == nil { adjust = padResult.adjust }
      if padResult.didGoBack { didGoBack = true }
    }
    if let activated, adjust?.id == activated, !MenuFocusRouter.isStepper(activated, in: model) { adjust = nil }
    return MenuFocusUpdate(focusedID: current, activatedID: activated, longActivatedID: longActivated, didGoBack: didGoBack, adjust: adjust)
  }

  /// Adopt the current physical input without emitting anything. `MenuScreen`
  /// calls this once, instead of `update`, on the very first tick after the
  /// screen appears — the button that *opened* this screen (e.g. A on a
  /// `.navigation` item in the parent) is still physically held on that
  /// first tick, and if focus already defaults to the first item (unlike
  /// a screen that starts with no highlight), an `update` call
  /// there would immediately activate it a second time. `resync` lets the
  /// nav engine observe that the button is down without treating it as a
  /// new press, so only a release-then-press after the screen is genuinely
  /// interactive counts.
  mutating func resync(_ input: MenuControllerNav.Input, at time: TimeInterval) {
    nav.resync(input, at: time)
    adjustOrigin = nil
  }

  /// Shared event-application core for both the single-pad `update` above
  /// and the multi-pad `update(padInputs:...)` -- kept as one function so
  /// the two paths cannot silently drift apart.
  ///
  /// With `columns` > 1 (`MenuStyle.grid`), up/down move one row and d-pad left/right move
  /// within the row (`gridMove`) instead of stepping a picker; a picker row still steps unless
  /// `stepsPickersInGrid` is false (`MenuStyle.tiles`: left/right always moves focus).
  /// With 1 (a list), up/down walk the flat order and left/right only ever step a picker.
  /// Neither direction ever activates: only A does.
  private static func apply(
    _ events: [MenuControllerNav.Event],
    model: MenuModel,
    focusedID: String?,
    columns: Int = 1,
    stepsPickersInGrid: Bool = true,
    adjustOrigin: inout String?
  ) -> MenuFocusUpdate {
    var current = focusedID
    var activated: String?
    var longActivated: String?
    var didGoBack = false
    var adjust: (id: String, step: Int)?
    for event in events {
      switch event {
      case .move(let step):
        current = columns > 1
          ? MenuFocusRouter.gridMove(current, rowStep: step, columnStep: 0, columns: columns, in: model)
          : MenuFocusRouter.move(current, by: step, in: model)
      case .jumpSection(let step):
        if let existing = current, let jumped = model.firstFocusableID(sectionOffsetFrom: existing, by: step) {
          current = jumped
        } else if current == nil {
          current = model.focusableIDs.first
        }
      case .activate:
        if let current { activated = current }
      case .longActivate:
        if let current { longActivated = current }
      case .back:
        didGoBack = true
      case .adjust(let step):
        if columns > 1, !stepsPickersInGrid || !MenuFocusRouter.isPicker(current, in: model) {
          current = MenuFocusRouter.gridMove(current, rowStep: 0, columnStep: step, columns: columns, in: model)
        } else if let current {
          adjust = (current, step)
          adjustOrigin = current
        }
      case .adjustRepeat(let step):
        // Only a stepper repeats: a 1...400 stepper needs ~400 presses otherwise. A cycle row keeps one step per press.
        // And only on the row the press landed on: a hold that slid onto a stepper needs a fresh press.
        if columns == 1, let current, current == adjustOrigin, MenuFocusRouter.isStepper(current, in: model) {
          adjust = (current, step)
        }
      }
    }
    // A and d-pad left/right on the same row in one tick: the activate already stepped a picker.
    // The builders' bindings read the snapshot the model was built from, so applying both would
    // write twice from the same stale value.
    // A stepper is the exception: A does nothing on it, so its adjust is not a second write.
    if let activated, adjust?.id == activated, !MenuFocusRouter.isStepper(activated, in: model) { adjust = nil }
    return MenuFocusUpdate(focusedID: current, activatedID: activated, longActivatedID: longActivated, didGoBack: didGoBack, adjust: adjust)
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

  /// Move through `model` laid out the way `MenuScreen`'s grid style draws it: `columns` cards
  /// per row, each section its own `LazyVGrid` (so a section always starts a new row, and its last
  /// row may be short), and a disabled item still taking up its cell.
  ///
  /// - `columnStep` moves within the current row only, clamped: it never wraps onto the next or
  ///   previous row. Disabled cells are skipped.
  /// - `rowStep` moves to the row above/below, onto the same column, clamped to a short row's last
  ///   card. If that card is disabled, the nearest enabled one in the row; a row with none is
  ///   skipped. Clamped at the first/last row.
  /// - No current focus (or a focus the model no longer has): the first focusable item, as `move`.
  static func gridMove(_ focusedID: String?, rowStep: Int, columnStep: Int, columns: Int, in model: MenuModel) -> String? {
    let columns = max(1, columns)
    var rows: [[MenuItem]] = []
    for section in model.sections {
      var start = 0
      while start < section.items.count {
        rows.append(Array(section.items[start ..< min(start + columns, section.items.count)]))
        start += columns
      }
    }
    guard let focusedID,
          let row = rows.firstIndex(where: { cells in cells.contains { $0.id == focusedID } }),
          let column = rows[row].firstIndex(where: { $0.id == focusedID }) else {
      return model.focusableIDs.first
    }
    if columnStep != 0 {
      var target = column + columnStep
      while rows[row].indices.contains(target) {
        if rows[row][target].isEnabled { return rows[row][target].id }
        target += columnStep
      }
      return focusedID
    }
    guard rowStep != 0 else { return focusedID }
    var target = row + rowStep
    while rows.indices.contains(target) {
      let cells = rows[target]
      let enabled = cells.indices.filter { cells[$0].isEnabled }
      if let nearest = enabled.min(by: { abs($0 - column) < abs($1 - column) }) {
        return cells[nearest].id
      }
      target += rowStep
    }
    return focusedID
  }

  private static func isStepper(_ id: String, in model: MenuModel) -> Bool {
    if case .stepper? = model.item(id: id)?.role { return true }
    return false
  }

  private static func isPicker(_ id: String?, in model: MenuModel) -> Bool {
    guard let id, let role = model.item(id: id)?.role else { return false }
    switch role {
    case .picker, .cycle, .stepper: return true
    default: return false
    }
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
  /// `previousOrder` either). A vanished id the host MOVED (the hub re-ids a
  /// player row across Wii and GameCube) follows `requestedID` first, when
  /// the model has it; a focused id that still exists is never overridden.
  static func reconcile(focusedID: String?, previousOrder: [String], model: MenuModel, requestedID: String? = nil) -> String? {
    let order = model.focusableIDs
    guard !order.isEmpty else { return nil }
    guard let focusedID else { return order.first }
    if order.contains(focusedID) { return focusedID }
    if let requestedID, order.contains(requestedID) { return requestedID }
    if let oldIndex = previousOrder.firstIndex(of: focusedID) {
      return order[min(oldIndex, order.count - 1)]
    }
    return order.first
  }
}

/// Result of one `MenuFocusRouter.update` tick.
struct MenuFocusUpdate {
  var focusedID: String?
  /// Set exactly when an activate edge fired on a currently-focused item.
  var activatedID: String?
  /// Set when A was held past the long-press threshold on a currently-focused item (tiles only).
  var longActivatedID: String?
  var didGoBack = false
  /// Set when a left/right edge fired on a currently-focused item.
  var adjust: (id: String, step: Int)?
}

extension MenuFocusUpdate: Equatable {
  static func == (lhs: MenuFocusUpdate, rhs: MenuFocusUpdate) -> Bool {
    lhs.focusedID == rhs.focusedID && lhs.activatedID == rhs.activatedID && lhs.longActivatedID == rhs.longActivatedID && lhs.didGoBack == rhs.didGoBack
      && lhs.adjust?.id == rhs.adjust?.id && lhs.adjust?.step == rhs.adjust?.step
  }
}

/// `MenuStyle.grid`'s column count. `MenuScreen` draws exactly this many columns and hands the
/// same number to `MenuFocusRouter`, so d-pad up/down lands on the card drawn above or below
/// rather than on the next card in reading order.
enum MenuGridLayout {
  static let minimumCardWidth: CGFloat = 320
  static let spacing: CGFloat = 12
  static let padding: CGFloat = 16

  /// Columns for a grid `width` points wide, its own padding included: as many
  /// `minimumCardWidth` cards as fit with `spacing` between them, never fewer than one. The same
  /// count `GridItem(.adaptive(minimum: 320), spacing: 12)` produced before the grid had to know it.
  static func columnCount(forWidth width: CGFloat) -> Int {
    let available = width - padding * 2
    guard available.isFinite, available > minimumCardWidth else { return 1 }
    return max(1, Int(((available + spacing) / (minimumCardWidth + spacing)).rounded(.down)))
  }
}
