import SwiftUI
import XCTest
@testable import iCube

final class QuickMenuTests: XCTestCase {
  private var pauseMenuOpens = 0

  private func model() -> MenuModel {
    let bindings = PauseMenuBindings(mute: .constant(false), fastForward: .constant(AnyHashable(-1)),
                                     quickSlot: .constant(AnyHashable(1)), shader: .constant(AnyHashable(0)))
    let noop: () -> Void = {}
    let actions = PauseMenuActions(resume: noop, quickSave: noop, quickLoad: noop, screenshot: noop, openSaveStates: noop,
                                   openCheats: noop, openControllers: noop, openShaders: noop, openContinuity: noop,
                                   openSettings: noop, openPerfOverlay: noop, requestReset: noop, requestExit: noop,
                                   recenterPointer: noop)
    let state = PauseMenuState(quickSlot: 1, isMuted: false, activeCheatCount: 0, shaderOptions: [], showsRecenterPointer: false)
    return QuickMenuModelBuilder.make(state: state, bindings: bindings, actions: actions) { self.pauseMenuOpens += 1 }
  }

  func test_itemIDs_inOrder() {
    XCTAssertEqual(model().allItems.map(\.id),
                   ["fast-forward", "mute", "quick-save", "quick-load", "screenshot", "record", "perf-hud", "pause-menu"])
    XCTAssertEqual(model().sections.count, 1)
    XCTAssertNil(model().sections[0].header)
  }

  func test_pauseMenuTile_callsThrough() {
    guard case .action(let run) = model().item(id: "pause-menu")?.role else { return XCTFail("pause-menu is not an action") }
    pauseMenuOpens = 0
    run()
    XCTAssertEqual(pauseMenuOpens, 1)
  }

  func test_unboundRemote_routesToQuickMenu() {
    let remote = PauseGestureTracker.siriRemoteMenuReason
    XCTAssertTrue(PauseGestureTracker.routesToQuickMenu(reason: remote, isUnboundRemote: true))
    XCTAssertFalse(PauseGestureTracker.routesToQuickMenu(reason: remote, isUnboundRemote: false))
    let uipress = PauseGestureTracker.uipressMenuReason
    XCTAssertTrue(PauseGestureTracker.routesToQuickMenu(reason: uipress, isUnboundRemote: true), "the UIPress route of the same press must agree")
    XCTAssertFalse(PauseGestureTracker.routesToQuickMenu(reason: uipress, isUnboundRemote: false))
    XCTAssertFalse(PauseGestureTracker.routesToQuickMenu(reason: PauseGestureTracker.optionsReason, isUnboundRemote: true))
  }

  func test_optionsHold_timing() {
    let hold = PauseGestureTracker.quickMenuHoldDuration
    XCTAssertFalse(PauseGestureTracker.optionsHoldFired(start: 10, now: 10 + hold - 0.01))
    XCTAssertTrue(PauseGestureTracker.optionsHoldFired(start: 10, now: 10 + hold))
    XCTAssertFalse(PauseGestureTracker.optionsHoldFired(start: 10, now: 10 + DOLMenuLongPressDuration))
  }
}
