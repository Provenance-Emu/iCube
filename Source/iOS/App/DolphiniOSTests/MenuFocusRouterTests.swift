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
}
