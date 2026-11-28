import SwiftUI
import XCTest
@testable import iCube

final class QuickMenuTests: XCTestCase {
  private var menuOpens = 0
  private var exitRequests = 0
  private var shaderOpens = 0
  private var aspect: AnyHashable = AnyHashable(0)

  private func model(shaderOptions: [(String, AnyHashable)] = []) -> MenuModel {
    let bindings = PauseMenuBindings(mute: .constant(false), fastForward: .constant(AnyHashable(-1)),
                                     quickSlot: .constant(AnyHashable(1)), shader: .constant(AnyHashable("")))
    let noop: () -> Void = {}
    let actions = PauseMenuActions(resume: noop, quickSave: noop, quickLoad: noop, screenshot: noop, openSaveStates: noop,
                                   openCheats: noop, openControllers: noop, openShaders: { self.shaderOpens += 1 }, openContinuity: noop,
                                   openSettings: noop, openPerfOverlay: noop, requestReset: noop,
                                   requestExit: { self.exitRequests += 1 }, recenterPointer: noop)
    let state = PauseMenuState(quickSlot: 1, isMuted: false, activeCheatCount: 0, shaderOptions: shaderOptions, showsRecenterPointer: false)
    let extras = QuickMenuExtras(aspect: Binding(get: { self.aspect }, set: { self.aspect = $0 }), openMenu: { self.menuOpens += 1 })
    return QuickMenuModelBuilder.make(state: state, bindings: bindings, actions: actions, extras: extras)
  }

  func test_itemIDs_inTwoRows() {
    let sections = model().sections
    XCTAssertEqual(sections.map(\.id), [QuickMenuModelBuilder.playSectionID, QuickMenuModelBuilder.displaySectionID])
    XCTAssertEqual(sections[0].items.map(\.id), ["fast-forward", "mute", "quick-save", "quick-load", "screenshot", "record"])
    XCTAssertEqual(sections[1].items.map(\.id), ["perf-hud", "scaling", "shaders", "menu", "exit"])
    for section in sections {
      XCTAssertLessThanOrEqual(section.items.count, QuickMenuModelBuilder.columns, "each section is one row")
    }
  }

  func test_nothingTheOldQuickMenuHadIsGone() {
    let ids = Set(model().allItems.map(\.id))
    for id in ["fast-forward", "mute", "quick-save", "quick-load", "screenshot", "record", "perf-hud"] {
      XCTAssertTrue(ids.contains(id), "\(id) was removed")
    }
  }

  func test_menuTile_isCalledMenuAndCallsThrough() {
    let item = model().item(id: QuickMenuModelBuilder.menuID)
    XCTAssertEqual(item?.title, L("Menu"))
    guard case .action(let run) = item?.role else { return XCTFail("menu is not an action") }
    menuOpens = 0
    run()
    XCTAssertEqual(menuOpens, 1)
  }

  func test_exitTile_isDestructiveAndAsksTheHost() {
    guard case .destructive(let run) = model().item(id: QuickMenuModelBuilder.exitID)?.role else { return XCTFail("exit is not destructive") }
    exitRequests = 0
    run()
    XCTAssertEqual(exitRequests, 1)
    XCTAssertEqual(model().allItems.last?.id, QuickMenuModelBuilder.exitID, "Exit is the last tile")
  }

  func test_scalingTile_showsAndCyclesTheAspect() {
    aspect = AnyHashable(0)
    let item = model().item(id: QuickMenuModelBuilder.scalingID)
    XCTAssertEqual(item?.currentValueTitle, L("Auto"))
    item?.activateInPlace()
    XCTAssertEqual(aspect, AnyHashable(1))
    XCTAssertEqual(model().item(id: QuickMenuModelBuilder.scalingID)?.currentValueTitle, "16:9")
    XCTAssertNotNil(item?.effectiveLongPress, "holding the tile lists every scaling mode")
  }

  func test_shadersTile_opensThePickerOrCyclesRecents() {
    shaderOpens = 0
    guard case .action(let open) = model().item(id: "shaders")?.role else { return XCTFail("with no recents the tile opens the picker") }
    open()
    XCTAssertEqual(shaderOpens, 1)

    let recents: [(String, AnyHashable)] = [("None", AnyHashable("")), ("crt-royale", AnyHashable("compiled_shaders/crt/crt-royale.oecompiledshader"))]
    let cycling = model(shaderOptions: recents).item(id: "shaders")
    XCTAssertEqual(cycling?.currentValueTitle, "None")
    guard case .action(let openFull)? = cycling?.effectiveLongPress else { return XCTFail("holding the tile opens the full picker") }
    openFull()
    XCTAssertEqual(shaderOpens, 2)
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
