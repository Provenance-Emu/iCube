// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class MenuFocusRouterTests: XCTestCase {

  private func item(_ id: String, enabled: Bool = true) -> MenuItem {
    MenuItem(id: id, title: id, role: .action({}), isEnabled: enabled)
  }

  /// Two sections so section-jump has somewhere to go.
  private func twoSectionModel() -> MenuModel {
    MenuModel(sections: [
      MenuSection(id: "s1", items: [item("a"), item("b"), item("c")]),
      MenuSection(id: "s2", items: [item("d"), item("e")]),
    ])
  }

  private var cfg: MenuControllerNav.Config {
    MenuControllerNav.Config(initialRepeatDelay: 0.4, repeatInterval: 0.08, stickEngage: 0.6, stickRelease: 0.3)
  }

  // MARK: Move

  func test_move_walksFlatFocusableOrder_noWrap() {
    var router = MenuFocusRouter(config: cfg)
    let model = twoSectionModel()
    let down = MenuControllerNav.Input(down: true)

    var result = router.update(down, at: 0, model: model, focusedID: nil, isActive: true)
    XCTAssertEqual(result.focusedID, "a", "no prior focus: first press lands on the first item")

    result = router.update(.init(), at: 0.01, model: model, focusedID: result.focusedID, isActive: true)
    result = router.update(down, at: 0.02, model: model, focusedID: result.focusedID, isActive: true)
    XCTAssertEqual(result.focusedID, "b")

    // Walk to the end and confirm it clamps rather than wraps.
    for t in stride(from: 0.03, through: 1.0, by: 0.05) {
      result = router.update(.init(), at: t, model: model, focusedID: result.focusedID, isActive: true)
      result = router.update(down, at: t + 0.01, model: model, focusedID: result.focusedID, isActive: true)
    }
    XCTAssertEqual(result.focusedID, "e", "clamped at the last item, never wraps to the first")
  }

  // MARK: Section jump

  func test_jumpSection_movesToFirstItemOfNextSection() {
    var router = MenuFocusRouter(config: cfg)
    let model = twoSectionModel()
    let result = router.update(.init(rightShoulder: true), at: 0, model: model, focusedID: "b", isActive: true)
    XCTAssertEqual(result.focusedID, "d")
  }

  func test_jumpSection_clampsAtLastSection() {
    var router = MenuFocusRouter(config: cfg)
    let model = twoSectionModel()
    let result = router.update(.init(rightShoulder: true), at: 0, model: model, focusedID: "e", isActive: true)
    XCTAssertEqual(result.focusedID, "e", "already in the last section: shoulder is a no-op, not a wrap")
  }

  func test_jumpSection_firesOncePerPress() {
    var router = MenuFocusRouter(config: cfg)
    let model = twoSectionModel()
    let held = MenuControllerNav.Input(rightShoulder: true)
    var result = router.update(held, at: 0, model: model, focusedID: "a", isActive: true)
    XCTAssertEqual(result.focusedID, "d")
    result = router.update(held, at: 0.1, model: model, focusedID: result.focusedID, isActive: true)
    XCTAssertEqual(result.focusedID, "d", "held forever never re-fires")
  }

  // MARK: Activate / back

  func test_activate_reportsCurrentlyFocusedItem() {
    var router = MenuFocusRouter(config: cfg)
    let model = twoSectionModel()
    let result = router.update(.init(a: true), at: 0, model: model, focusedID: "c", isActive: true)
    XCTAssertEqual(result.activatedID, "c")
    XCTAssertEqual(result.focusedID, "c", "activate does not itself move focus")
  }

  func test_activate_withNoFocus_reportsNothing() {
    var router = MenuFocusRouter(config: cfg)
    let model = twoSectionModel()
    let result = router.update(.init(a: true), at: 0, model: model, focusedID: nil, isActive: true)
    XCTAssertNil(result.activatedID)
  }

  func test_back_setsFlag() {
    var router = MenuFocusRouter(config: cfg)
    let model = twoSectionModel()
    let result = router.update(.init(b: true), at: 0, model: model, focusedID: "a", isActive: true)
    XCTAssertTrue(result.didGoBack)
  }

  // MARK: Claim-ignore (a covering MenuScreen/sheet owns the controller)

  func test_inactiveTicks_emitNothing() {
    var router = MenuFocusRouter(config: cfg)
    let model = twoSectionModel()
    let result = router.update(.init(down: true, a: true), at: 0, model: model, focusedID: "a", isActive: false)
    XCTAssertNil(result.activatedID)
    XCTAssertEqual(result.focusedID, "a", "focus is reported back unchanged, not cleared")
    XCTAssertFalse(result.didGoBack)
  }

  /// Regression for the double-back bug: a naive "just don't process input
  /// while inactive" implementation leaves the nav engine's B-latch stuck at
  /// `false`. If the same physical B press that dismissed a covering sheet is
  /// still held the instant this screen regains ownership, that implementation
  /// reads `false -> true` as a brand new press and fires a second `.back`.
  /// `MenuFocusRouter` must resync every inactive tick so the latch already
  /// reads "held" by the time ownership returns.
  func test_heldButtonAcrossReactivation_emitsNothingUntilReleasedAndPressedAgain() {
    var router = MenuFocusRouter(config: cfg)
    let model = twoSectionModel()
    let held = MenuControllerNav.Input(b: true)

    // The press that dismissed the covering surface arrives on an inactive tick.
    var result = router.update(held, at: 0, model: model, focusedID: "a", isActive: false)
    XCTAssertFalse(result.didGoBack)

    // Ownership returns on the very next tick; the button is still down.
    result = router.update(held, at: 0.01, model: model, focusedID: "a", isActive: true)
    XCTAssertFalse(result.didGoBack, "the still-held press must not read as a new edge")

    // Release, then a genuine new press does fire.
    result = router.update(.init(), at: 0.02, model: model, focusedID: "a", isActive: true)
    XCTAssertFalse(result.didGoBack)
    result = router.update(held, at: 0.03, model: model, focusedID: "a", isActive: true)
    XCTAssertTrue(result.didGoBack)
  }

  // MARK: Open-press leak (the press that opened this screen)

  /// The A that pushed this screen (e.g. a `.navigation` item in the parent)
  /// is still physically held on the very first tick. `MenuScreen` calls
  /// `resync` instead of `update` on that first tick specifically to prevent
  /// it from reading as an immediate activate of whatever item focus
  /// defaults to.
  func test_resyncOnFirstTick_preventsOpenPressActivation() {
    var router = MenuFocusRouter(config: cfg)
    let model = twoSectionModel()
    let heldA = MenuControllerNav.Input(a: true)

    router.resync(heldA, at: 0)
    var result = router.update(heldA, at: 0.01, model: model, focusedID: "a", isActive: true)
    XCTAssertNil(result.activatedID, "the open press must not immediately activate the default-focused item")

    result = router.update(.init(), at: 0.02, model: model, focusedID: "a", isActive: true)
    result = router.update(heldA, at: 0.03, model: model, focusedID: "a", isActive: true)
    XCTAssertEqual(result.activatedID, "a", "release then press activates normally")
  }

  // MARK: Reconcile (model rebuilt out from under a live focus — §1)

  func test_reconcile_keepsFocusIfStillPresent() {
    let model = twoSectionModel()
    XCTAssertEqual(MenuFocusRouter.reconcile(focusedID: "c", previousOrder: ["a", "b", "c", "d", "e"], model: model), "c")
  }

  func test_reconcile_fallsBackToNearestSurvivingIndex() {
    // "b" (index 1) is removed; the item now at index 1 should pick up focus.
    let model = MenuModel(sections: [
      MenuSection(id: "s1", items: [item("a"), item("c")]),
      MenuSection(id: "s2", items: [item("d"), item("e")]),
    ])
    let result = MenuFocusRouter.reconcile(focusedID: "b", previousOrder: ["a", "b", "c", "d", "e"], model: model)
    XCTAssertEqual(result, "c")
  }

  func test_reconcile_fallsBackToFirstItemWhenNoNearestIndex() {
    let model = twoSectionModel()
    let result = MenuFocusRouter.reconcile(focusedID: "nope", previousOrder: [], model: model)
    XCTAssertEqual(result, "a")
  }

  func test_reconcile_emptyModel_returnsNil() {
    let empty = MenuModel(sections: [])
    XCTAssertNil(MenuFocusRouter.reconcile(focusedID: "a", previousOrder: ["a"], model: empty))
  }

  func test_reconcile_nilFocus_returnsFirstItem() {
    let model = twoSectionModel()
    XCTAssertEqual(MenuFocusRouter.reconcile(focusedID: nil, previousOrder: [], model: model), "a")
  }

  // MARK: Multi-pad merge (D18 engine gap #3 — "MenuScreen listens only to
  // the first connected extended gamepad")

  /// One pad moves, another activates, in the same tick: both edges must
  /// apply -- the move against the tick's starting focus, the activate
  /// against whatever `focusedID` was passed in (not the just-moved one,
  /// since pad order here is activate-then-move) -- with no edge dropped.
  func test_multiPad_oneHoldsA_otherMoves_bothEdgesApply() {
    var router = MenuFocusRouter(config: cfg)
    let model = twoSectionModel()
    let p1 = AnyHashable("p1")
    let p2 = AnyHashable("p2")

    // Seed both pads as "known" (idle) first, so the next tick's edges are
    // genuine presses, not first-sight resyncs.
    _ = router.update(padInputs: [(p1, .init()), (p2, .init())], at: 0, model: model, focusedID: nil, isActive: true)

    // p1 holds A on the currently-focused item; p2 presses down.
    let result = router.update(
      padInputs: [(p1, .init(a: true)), (p2, .init(down: true))],
      at: 0.1, model: model, focusedID: "a", isActive: true
    )
    XCTAssertEqual(result.activatedID, "a", "p1's activate fires against the focus at the start of the tick")
    XCTAssertEqual(result.focusedID, "b", "p2's move still applies in the same tick")
  }

  /// Two pads pressing A in the very same tick must not double-activate --
  /// and once both are latched down, holding on a later tick must not
  /// re-fire either.
  func test_multiPad_bothPressAInSameTick_exactlyOneActivation_noReplayWhileHeld() {
    var router = MenuFocusRouter(config: cfg)
    let model = twoSectionModel()
    let p1 = AnyHashable("p1")
    let p2 = AnyHashable("p2")
    _ = router.update(padInputs: [(p1, .init()), (p2, .init())], at: 0, model: model, focusedID: nil, isActive: true)

    let result = router.update(
      padInputs: [(p1, .init(a: true)), (p2, .init(a: true))],
      at: 0.1, model: model, focusedID: "b", isActive: true
    )
    XCTAssertEqual(result.activatedID, "b", "the first pad's edge wins; the second is not a second activation")

    let held = router.update(
      padInputs: [(p1, .init(a: true)), (p2, .init(a: true))],
      at: 0.2, model: model, focusedID: result.focusedID, isActive: true
    )
    XCTAssertNil(held.activatedID, "both pads' latches are already down; holding never replays")
  }

  /// A pad seen for the very first time, already holding A, must not read
  /// that hold as a fresh press-edge (mirrors the single-pad open-press-leak
  /// regression, per-pad).
  func test_multiPad_newPadFirstSeenWithAHeld_noPhantomActivation() {
    var router = MenuFocusRouter(config: cfg)
    let model = twoSectionModel()
    let p1 = AnyHashable("p1")

    let result = router.update(padInputs: [(p1, .init(a: true))], at: 0, model: model, focusedID: "a", isActive: true)
    XCTAssertNil(result.activatedID, "a pad's very first tick is a resync, never treated as a fresh edge")

    let released = router.update(padInputs: [(p1, .init())], at: 0.1, model: model, focusedID: "a", isActive: true)
    XCTAssertNil(released.activatedID)
    let pressed = router.update(padInputs: [(p1, .init(a: true))], at: 0.2, model: model, focusedID: "a", isActive: true)
    XCTAssertEqual(pressed.activatedID, "a", "release then press activates normally")
  }

  /// A second pad connecting mid-session (after the first pad is already
  /// known) must be resynced on ITS first sighting too, even though the
  /// first pad is not new -- a controller woken mid-screen must not produce
  /// a phantom edge just because other pads are already established.
  func test_multiPad_padConnectingMidSession_isResyncedNotUpdated() {
    var router = MenuFocusRouter(config: cfg)
    let model = twoSectionModel()
    let p1 = AnyHashable("p1")
    let p2 = AnyHashable("p2")

    // p1 already known and idle.
    _ = router.update(padInputs: [(p1, .init())], at: 0, model: model, focusedID: "a", isActive: true)

    // p2 connects mid-session already holding A; p1 stays idle this tick.
    let result = router.update(
      padInputs: [(p1, .init()), (p2, .init(a: true))],
      at: 0.5, model: model, focusedID: "a", isActive: true
    )
    XCTAssertNil(result.activatedID, "p2's first sighting resyncs rather than reading the held A as a fresh press")

    let released = router.update(padInputs: [(p1, .init()), (p2, .init())], at: 0.6, model: model, focusedID: "a", isActive: true)
    XCTAssertNil(released.activatedID)
    let pressed = router.update(padInputs: [(p1, .init()), (p2, .init(a: true))], at: 0.7, model: model, focusedID: "a", isActive: true)
    XCTAssertEqual(pressed.activatedID, "a", "once p2 is known, a genuine release-then-press activates normally")
  }

  // MARK: Adjust (d-pad left/right)

  func test_adjust_reportsFocusedItemAndDirection_oncePerPress() {
    var router = MenuFocusRouter(config: cfg)
    let model = twoSectionModel()
    var right = MenuControllerNav.Input()
    right.right = true
    let first = router.update(right, at: 0, model: model, focusedID: "b", isActive: true)
    XCTAssertEqual(first.adjust?.id, "b")
    XCTAssertEqual(first.adjust?.step, 1)
    let held = router.update(right, at: 1, model: model, focusedID: "b", isActive: true)
    XCTAssertNil(held.adjust, "a held right must not repeat")
    _ = router.update(MenuControllerNav.Input(), at: 1.1, model: model, focusedID: "b", isActive: true)
    var left = MenuControllerNav.Input()
    left.left = true
    let back = router.update(left, at: 1.2, model: model, focusedID: "b", isActive: true)
    XCTAssertEqual(back.adjust?.step, -1)
  }

  func test_adjust_withNoFocus_reportsNothing() {
    var router = MenuFocusRouter(config: cfg)
    var right = MenuControllerNav.Input()
    right.right = true
    XCTAssertNil(router.update(right, at: 0, model: twoSectionModel(), focusedID: nil, isActive: true).adjust)
  }

  /// A and d-pad right in the same tick on a picker row: the activate already stepped it. The
  /// builders' bindings read the model's snapshot, so applying the adjust too would write a second
  /// time from the same stale value.
  func test_adjust_isDroppedWhenTheSameTickActivatesThatRow() {
    var router = MenuFocusRouter(config: cfg)
    let result = router.update(.init(a: true, right: true), at: 0, model: twoSectionModel(), focusedID: "b", isActive: true)
    XCTAssertEqual(result.activatedID, "b")
    XCTAssertNil(result.adjust, "the activate already changed the row")
  }

  func test_multiPad_adjustIsDroppedWhenAnotherPadActivatesThatRow() {
    var router = MenuFocusRouter(config: cfg)
    let model = twoSectionModel()
    let p1 = AnyHashable("p1")
    let p2 = AnyHashable("p2")
    _ = router.update(padInputs: [(p1, .init()), (p2, .init())], at: 0, model: model, focusedID: "b", isActive: true)
    let result = router.update(
      padInputs: [(p1, .init(a: true)), (p2, .init(right: true))],
      at: 0.1, model: model, focusedID: "b", isActive: true)
    XCTAssertEqual(result.activatedID, "b")
    XCTAssertNil(result.adjust)
  }

  /// The guard only drops an adjust on the SAME row that was activated. One pad presses A on "b"
  /// while another moves down to "c" and steps it in the same tick: both apply.
  func test_multiPad_adjustOnADifferentRowThanTheActivatedOne_stillApplies() {
    var router = MenuFocusRouter(config: cfg)
    let model = twoSectionModel()
    let p1 = AnyHashable("p1")
    let p2 = AnyHashable("p2")
    _ = router.update(padInputs: [(p1, .init()), (p2, .init())], at: 0, model: model, focusedID: "b", isActive: true)
    let result = router.update(
      padInputs: [(p1, .init(a: true)), (p2, .init(down: true, right: true))],
      at: 0.1, model: model, focusedID: "b", isActive: true)
    XCTAssertEqual(result.activatedID, "b")
    XCTAssertEqual(result.adjust?.id, "c", "a different row: the guard must not drop it")
    XCTAssertEqual(result.adjust?.step, 1)
  }

  /// `padBackNavigation()` feeds the router an empty model: B must still report back, and nothing
  /// else may happen.
  func test_back_withAnEmptyModel_stillReportsBack() {
    var router = MenuFocusRouter(config: cfg)
    let p1 = AnyHashable("p1")
    _ = router.update(padInputs: [(p1, .init())], at: 0, model: MenuModel(), focusedID: nil, isActive: true)
    let result = router.update(padInputs: [(p1, .init(b: true))], at: 0.1, model: MenuModel(), focusedID: nil, isActive: true)
    XCTAssertTrue(result.didGoBack)
    XCTAssertNil(result.focusedID)
    XCTAssertNil(result.activatedID)
  }

  // MARK: Grid (`MenuStyle.grid`)

  /// Laid out three columns wide:
  ///
  ///     a b c
  ///     d e f
  ///     g
  private func gridModel() -> MenuModel {
    MenuModel(sections: [MenuSection(id: "s1", items: ["a", "b", "c", "d", "e", "f", "g"].map { item($0) })])
  }

  /// `gridMove` on a three-column grid.
  private func gridMove(_ id: String?, rowStep: Int = 0, columnStep: Int = 0, in model: MenuModel) -> String? {
    MenuFocusRouter.gridMove(id, rowStep: rowStep, columnStep: columnStep, columns: 3, in: model)
  }

  func test_gridMove_upAndDown_keepTheColumn() {
    let model = gridModel()
    XCTAssertEqual(gridMove("b", rowStep: 1, in: model), "e", "down lands on the card below, not the next one")
    XCTAssertEqual(gridMove("e", rowStep: -1, in: model), "b")
  }

  func test_gridMove_downIntoAShortRow_clampsToItsLastCard() {
    XCTAssertEqual(gridMove("f", rowStep: 1, in: gridModel()), "g")
  }

  func test_gridMove_leftAndRight_stayInTheRow() {
    let model = gridModel()
    XCTAssertEqual(gridMove("a", columnStep: 1, in: model), "b")
    XCTAssertEqual(gridMove("e", columnStep: -1, in: model), "d")
    XCTAssertEqual(gridMove("c", columnStep: 1, in: model), "c", "right at the row's end does not wrap to the next row")
    XCTAssertEqual(gridMove("d", columnStep: -1, in: model), "d", "left at the row's start does not wrap to the previous row")
  }

  func test_gridMove_clampsAtTheTopAndBottom() {
    let model = gridModel()
    XCTAssertEqual(gridMove("b", rowStep: -1, in: model), "b")
    XCTAssertEqual(gridMove("g", rowStep: 1, in: model), "g")
  }

  func test_gridMove_withNoFocus_landsOnTheFirstItem() {
    XCTAssertEqual(gridMove(nil, rowStep: 1, in: gridModel()), "a")
  }

  /// Each section is its own `LazyVGrid`, so it starts a new row.
  func test_gridMove_eachSectionStartsANewRow() {
    let model = twoSectionModel()  // [a b c] [d e], two columns: a b / c / d e
    let move = { (id: String, rows: Int) in
      MenuFocusRouter.gridMove(id, rowStep: rows, columnStep: 0, columns: 2, in: model)
    }
    XCTAssertEqual(move("b", 1), "c")
    XCTAssertEqual(move("c", 1), "d")
    XCTAssertEqual(move("e", -1), "c")
  }

  /// A disabled card keeps its cell but is never focused.
  func test_gridMove_skipsDisabledCards() {
    let model = MenuModel(sections: [MenuSection(id: "s1", items: [
      item("a"), item("b"), item("c"),
      item("d", enabled: false), item("e"), item("f"),
    ])])
    XCTAssertEqual(gridMove("a", rowStep: 1, in: model), "e", "nearest enabled card in the row below")
    XCTAssertEqual(gridMove("f", columnStep: -1, in: model), "e")
    XCTAssertEqual(gridMove("e", columnStep: -1, in: model), "e", "nothing enabled to the left")
  }

  func test_grid_downMovesARow_rightMovesWithinIt_neitherAdjusts() {
    var router = MenuFocusRouter(config: cfg)
    let model = gridModel()
    var result = router.update(.init(down: true), at: 0, model: model, focusedID: "b", isActive: true, columns: 3)
    XCTAssertEqual(result.focusedID, "e")
    result = router.update(.init(), at: 0.01, model: model, focusedID: result.focusedID, isActive: true, columns: 3)
    result = router.update(.init(right: true), at: 0.02, model: model, focusedID: result.focusedID, isActive: true, columns: 3)
    XCTAssertEqual(result.focusedID, "f")
    XCTAssertNil(result.adjust, "in a grid, right moves focus; it does not step the card")
  }

  /// `MenuScreen` drives the multi-pad path; the column count must reach it too.
  func test_multiPad_grid_downMovesARow() {
    var router = MenuFocusRouter(config: cfg)
    let model = gridModel()
    let p1 = AnyHashable("p1")
    _ = router.update(padInputs: [(p1, .init())], at: 0, model: model, focusedID: "b", isActive: true, columns: 3)
    let result = router.update(padInputs: [(p1, .init(down: true))], at: 0.1, model: model, focusedID: "b", isActive: true, columns: 3)
    XCTAssertEqual(result.focusedID, "e")
    XCTAssertNil(result.activatedID)
  }

  /// D-pad down, pressed or held long enough to repeat, only ever moves: in a list and in a
  /// grid. Only A activates.
  func test_down_neverActivates() {
    for columns in [1, 3] {
      var router = MenuFocusRouter(config: cfg)
      let model = gridModel()
      var focused: String? = "a"
      for t in stride(from: 0.0, through: 1.0, by: 0.05) {
        let result = router.update(.init(down: true), at: t, model: model, focusedID: focused, isActive: true, columns: columns)
        XCTAssertNil(result.activatedID, "\(columns) column(s): down activated a row")
        XCTAssertNil(result.adjust)
        focused = result.focusedID
      }
      XCTAssertEqual(focused, "g", "\(columns) column(s): down walked to the last row")
    }
  }

  func test_gridColumnCount_followsTheWidth() {
    XCTAssertEqual(MenuGridLayout.columnCount(forWidth: 390), 1, "iPhone portrait")
    XCTAssertEqual(MenuGridLayout.columnCount(forWidth: 834), 2, "11-inch iPad portrait")
    XCTAssertEqual(MenuGridLayout.columnCount(forWidth: 1194), 3, "11-inch iPad landscape")
    XCTAssertEqual(MenuGridLayout.columnCount(forWidth: 683), 1, "one point short of two 320pt cards")
    XCTAssertEqual(MenuGridLayout.columnCount(forWidth: 684), 2, "two 320pt cards, 12pt apart, 16pt padding")
    XCTAssertEqual(MenuGridLayout.columnCount(forWidth: 0), 1)
  }
}
