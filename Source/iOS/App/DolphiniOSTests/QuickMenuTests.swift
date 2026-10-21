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

  func test_remoteMenuRoutesAgreeAndLiveRequiresExplicitPreferenceAndGameplayPad() {
    for reason in [PauseGestureTracker.siriRemoteMenuReason, PauseGestureTracker.uipressMenuReason] {
      XCTAssertFalse(PauseGestureTracker.routesToLivePerformance(reason: reason, preference: .pauseMenu, hasGameplayController: true, isPaused: false))
      XCTAssertTrue(PauseGestureTracker.routesToLivePerformance(reason: reason, preference: .livePerformance, hasGameplayController: true, isPaused: false))
      XCTAssertFalse(PauseGestureTracker.routesToLivePerformance(reason: reason, preference: .livePerformance, hasGameplayController: false, isPaused: false))
      XCTAssertFalse(PauseGestureTracker.routesToLivePerformance(reason: reason, preference: .livePerformance, hasGameplayController: true, isPaused: true))
    }
    XCTAssertFalse(PauseGestureTracker.routesToLivePerformance(reason: PauseGestureTracker.optionsReason,
      preference: .livePerformance, hasGameplayController: true, isPaused: false))
  }

  func test_optionsHold_timing() {
    let hold = PauseGestureTracker.quickMenuHoldDuration
    XCTAssertFalse(PauseGestureTracker.optionsHoldFired(start: 10, now: 10 + hold - 0.01))
    XCTAssertTrue(PauseGestureTracker.optionsHoldFired(start: 10, now: 10 + hold))
    XCTAssertFalse(PauseGestureTracker.optionsHoldFired(start: 10, now: 10 + DOLMenuLongPressDuration))
  }
}
