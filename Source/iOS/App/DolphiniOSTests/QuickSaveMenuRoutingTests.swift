// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import XCTest
@testable import iCube

@MainActor
final class QuickSaveMenuRoutingTests: XCTestCase {
  @MainActor
  private final class Fixture {
    var mode: QuickSaveMode = .history
    var modded = false
    var current = true
    var active = true
    var slot = 4
    var historyWrites = 0
    var browsers = 0
    var dismissals = 0
    var loaded: [URL] = []
    var outcomes: [QuickSaveActions.Outcome] = []
    var invalidateWhileScanning = false
    var invalidateDuringHistorySave = false
    let session = QuickSaveSurfaceSession(gameID: "GALE01", identifier: 7)
    let classic = URL(fileURLWithPath: "/states/GALE01.s04")
    let history = URL(fileURLWithPath: "/states/GALE01.quick-A2CC29A2-38BC-41B6-B37C-7624990EAE90.s01")
    let automatic = URL(fileURLWithPath: "/states/GALE01.auto")
    var states: [SaveStateInfo] = []

    init() { states = [state(classic, slot: 4, time: 10), state(history, time: 20), state(automatic, time: 100, auto: true)] }
    func state(_ path: URL, slot: Int? = nil, time: TimeInterval, compatible: Bool = true, auto: Bool = false) -> SaveStateInfo {
      SaveStateInfo(gameID: "GALE01", displayName: path.lastPathComponent, slot: slot, createdAt: nil,
        modifiedAt: Date(timeIntervalSince1970: time), sizeBytes: nil, versionHash: nil,
        isCompatible: compatible, path: path, thumbnailURL: nil, isAuto: auto, isQuickSave: path == history)
    }
    var environment: QuickSaveActions.LoadEnvironment {
      .init(session: { self.session }, isCurrent: { self.current && $0 == self.session }, allowed: { true },
        isModded: { self.modded }, states: { _ in
          if self.invalidateWhileScanning { self.current = false }
          return self.states
        }, slotPath: { _ in self.classic }, exists: { path in self.states.contains { $0.path == path } },
        compatible: { path in self.states.first { $0.path == path }?.isCompatible == true },
        request: { path, session in
          guard self.current, session == self.session else { return false }
          self.loaded.append(path); return true
        })
    }
    func controller() -> QuickSaveMenuActions {
      QuickSaveMenuActions(mode: { self.mode }, slot: { self.slot }, session: session,
        isActive: { self.active }, runtime: .init(isCurrent: { self.current && $0 == self.session },
          isModded: { self.modded }, saveHistory: { expected in
            XCTAssertEqual(expected, self.session)
            self.historyWrites += 1
            if self.invalidateDuringHistorySave { self.current = false }
            return .saved(self.history)
          },
          load: { await QuickSaveActions.load(mode: $0, slot: $1, expectedSession: $2, environment: self.environment) }),
        dismiss: { self.dismissals += 1; self.active = false }, openBrowser: { self.browsers += 1 }, report: { self.outcomes.append($0) })
    }
  }

  private func model(quickMenu: Bool, fixture: Fixture, controller: QuickSaveMenuActions) -> MenuModel {
    let bindings = PauseMenuBindings(mute: .constant(false), fastForward: .constant(AnyHashable(-1)),
      quickSlot: .constant(AnyHashable(fixture.slot)), shader: .constant(AnyHashable(0)), quickSaveMode: .constant(fixture.mode))
    let actions = QuickMenuHost.actions(quickActions: controller, openPerfOverlay: {})
    let state = PauseMenuState(quickSlot: fixture.slot, isMuted: false, activeCheatCount: 0,
      shaderOptions: [], showsRecenterPointer: false, quickSaveMode: fixture.mode, isModded: fixture.modded)
    if quickMenu { return QuickMenuModelBuilder.make(state: state, bindings: bindings, actions: actions) }
    return PauseMenuModelBuilder.primaryLayout(PauseMenuModelBuilder.make(state: state, bindings: bindings, actions: actions))
  }

  func testAdmissionDismissesImmediatelyAndSurvivesItsOwnSurfaceClosing() async {
    for saving in [false, true] {
      let fixture = Fixture()
      let actions = fixture.controller()
      if saving { actions.save() } else { actions.load() }
      XCTAssertEqual(fixture.dismissals, 1)
      XCTAssertFalse(fixture.active)
      await actions.task?.value
      XCTAssertEqual(saving ? fixture.historyWrites : fixture.loaded.count, 1)
      XCTAssertEqual(fixture.outcomes.count, 1)
    }
  }

  func testProductionPauseAndQuickMenuHistoryActionsCreateHistoryAndLoadNewestManual() async {
    for quick in [false, true] {
      let fixture = Fixture()
      // Use one shared live fixture for both the production model and its action dependencies.
      let actions = fixture.controller()
      let menu = model(quickMenu: quick, fixture: fixture, controller: actions)
      menu.item(id: "quick-save")?.activateInPlace()
      await actions.task?.value
      XCTAssertEqual(fixture.historyWrites, 1)
      XCTAssertEqual(fixture.browsers, 0)
      fixture.active = true
      menu.item(id: "quick-load")?.activateInPlace()
      await actions.task?.value
      XCTAssertEqual(fixture.loaded, [fixture.history])
      XCTAssertEqual(fixture.outcomes.last, .loadRequested(fixture.history))
    }
  }

  func testProductionMenusOfferBrowserForNewestIncompatibleManualWithoutOlderSlotFallback() async {
    for quick in [false, true] {
      let fixture = Fixture()
      fixture.states[1] = fixture.state(fixture.history, time: 20, compatible: false)
      let actions = fixture.controller()
      model(quickMenu: quick, fixture: fixture, controller: actions).item(id: "quick-load")?.activateInPlace()
      await actions.task?.value
      XCTAssertTrue(fixture.loaded.isEmpty)
      XCTAssertEqual(fixture.browsers, 1)
      XCTAssertEqual(fixture.outcomes, [.incompatible(fixture.history)])
    }
  }

  func testProductionMenusUseAutomaticResumeOnlyWhenNoManualStateExists() async {
    for quick in [false, true] {
      let fixture = Fixture()
      fixture.states = [fixture.state(fixture.automatic, time: 100, auto: true)]
      let actions = fixture.controller()
      model(quickMenu: quick, fixture: fixture, controller: actions).item(id: "quick-load")?.activateInPlace()
      await actions.task?.value
      XCTAssertEqual(fixture.loaded, [fixture.automatic])
    }
  }

  func testClassicAndModdedQuickSaveEnterConsentBrowserWithSelectedSlotPreserved() {
    for quick in [false, true] {
      for modded in [false, true] {
        let fixture = Fixture()
        fixture.mode = modded ? .history : .slots
        fixture.modded = modded
        let actions = fixture.controller()
        let menu = model(quickMenu: quick, fixture: fixture, controller: actions)
        menu.item(id: "quick-save")?.activateInPlace()
        XCTAssertEqual(fixture.browsers, 1)
        XCTAssertEqual(fixture.historyWrites, 0)
        XCTAssertEqual(fixture.slot, 4)
        XCTAssertEqual(menu.item(id: "quick-save")?.badge, "Slot 4")
        guard case .options(_, let choices, _)? = menu.item(id: "quick-save")?.effectiveLongPress else { return XCTFail("Classic slot picker required") }
        XCTAssertEqual(choices.count, 10)
      }
    }
  }

  func testClassicAndModdedQuickLoadUseCheckedSelectedFileInBothMenus() async {
    for quick in [false, true] {
      for modded in [false, true] {
        let fixture = Fixture()
        fixture.mode = modded ? .history : .slots
        fixture.modded = modded
        let actions = fixture.controller()
        model(quickMenu: quick, fixture: fixture, controller: actions).item(id: "quick-load")?.activateInPlace()
        await actions.task?.value
        XCTAssertEqual(fixture.loaded, [fixture.classic])
        XCTAssertEqual(fixture.outcomes, [.loadRequested(fixture.classic)])
      }
    }
  }

  func testLoadAwaitsCompletionAndNeverReportsRejectedDeserializationAsSuccess() async {
    let fixture = Fixture()
    var environment = fixture.environment
    var finish: CheckedContinuation<Bool, Never>?
    environment.requestCompletion = { _, _ in
      await withCheckedContinuation { finish = $0 }
    }
    let task = Task { @MainActor in
      await QuickSaveActions.load(mode: .slots, slot: 4, expectedSession: fixture.session, environment: environment)
    }
    while finish == nil { await Task.yield() }
    XCTAssertTrue(fixture.loaded.isEmpty, "Legacy admission-only path must not run")
    finish?.resume(returning: false)
    let outcome = await task.value
    XCTAssertEqual(outcome, .unavailable)
    XCTAssertFalse(outcome.isSuccess)
  }

  func testHistorySaveCompletionFromReplacedSessionHasNoSuccessMessage() async {
    for quick in [false, true] {
      let fixture = Fixture()
      fixture.invalidateDuringHistorySave = true
      let actions = fixture.controller()
      model(quickMenu: quick, fixture: fixture, controller: actions).item(id: "quick-save")?.activateInPlace()
      await actions.task?.value
      XCTAssertEqual(fixture.historyWrites, 1)
      XCTAssertTrue(fixture.outcomes.isEmpty)
      XCTAssertEqual(fixture.browsers, 0)
    }
  }

  func testHistoryMenuPresentationHasNoClassicSlotBadgeOrLongPress() {
    let fixture = Fixture()
    let actions = fixture.controller()
    let menu = model(quickMenu: true, fixture: fixture, controller: actions)
    XCTAssertEqual(menu.item(id: "quick-save")?.badge, "Quick-save history")
    XCTAssertEqual(menu.item(id: "quick-load")?.badge, "Latest manual")
    XCTAssertNil(menu.item(id: "quick-save")?.effectiveLongPress)
    XCTAssertNil(menu.item(id: "quick-load")?.effectiveLongPress)
    XCTAssertTrue(menu.item(id: "quick-load")?.description?.contains("automatic resume") == true)
  }

  func testLoadFacadeCannotRebindCapturedTapToAReplacementSession() async {
    let fixture = Fixture()
    var environment = fixture.environment
    let replacement = QuickSaveSurfaceSession(gameID: "GALE01", identifier: 8)
    environment.session = { replacement }
    environment.isCurrent = { $0 == replacement }
    let outcome = await QuickSaveActions.load(mode: .history, slot: 4,
      expectedSession: fixture.session, environment: environment)
    XCTAssertEqual(outcome, .unavailable)
    XCTAssertTrue(fixture.loaded.isEmpty)
  }

  func testStaleSessionAndDismissedSurfaceSuppressOldActionsAndCompletions() async {
    for quick in [false, true] {
      let fixture = Fixture()
      let actions = fixture.controller()
      let menu = model(quickMenu: quick, fixture: fixture, controller: actions)
      fixture.current = false
      menu.item(id: "quick-save")?.activateInPlace()
      menu.item(id: "quick-load")?.activateInPlace()
      XCTAssertEqual(fixture.historyWrites, 0)
      XCTAssertTrue(fixture.loaded.isEmpty)
      fixture.current = true
      fixture.invalidateWhileScanning = true
      menu.item(id: "quick-load")?.activateInPlace()
      await actions.task?.value
      XCTAssertTrue(fixture.loaded.isEmpty)
      XCTAssertTrue(fixture.outcomes.isEmpty)
      XCTAssertEqual(fixture.browsers, 0)
      fixture.current = true; fixture.active = false
      menu.item(id: "quick-save")?.activateInPlace()
      XCTAssertEqual(fixture.historyWrites, 0)
    }
  }
}
