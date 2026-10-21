// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import XCTest
@testable import iCube

final class RemotePerformanceNavigationTests: XCTestCase {
  func testRemotePreferenceDefaultsSafelyAndRoundTripsWithoutGlobalDefaults() {
    let name = "RemotePerformanceNavigationTests.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    XCTAssertEqual(SiriRemoteMenuAction.stored(in: defaults), .pauseMenu)
    SiriRemoteMenuAction.livePerformance.store(in: defaults)
    XCTAssertEqual(SiriRemoteMenuAction.stored(in: defaults), .livePerformance)
    defaults.set("unknown future action", forKey: SiriRemoteMenuAction.defaultsKey)
    XCTAssertEqual(SiriRemoteMenuAction.stored(in: defaults), .pauseMenu)
  }

  func testLivePreferenceRequiresGameplayControllerAndRunningGame() {
    XCTAssertFalse(SiriRemoteMenuAction.pauseMenu.opensLive(hasGameplayController: true, isPaused: false))
    XCTAssertFalse(SiriRemoteMenuAction.livePerformance.opensLive(hasGameplayController: false, isPaused: false))
    XCTAssertFalse(SiriRemoteMenuAction.livePerformance.opensLive(hasGameplayController: true, isPaused: true))
    XCTAssertTrue(SiriRemoteMenuAction.livePerformance.opensLive(hasGameplayController: true, isPaused: false))
  }

  func testNavigationSkipsDisabledRowsAndClampsAtEnds() {
    var nav = RemotePerformanceNavigation()
    nav.reconcile([.init(id: "a"), .init(id: "disabled", enabled: false), .init(id: "b")])
    XCTAssertEqual(nav.selectedID, "a")
    nav.move(-1)
    XCTAssertEqual(nav.selectedID, "a")
    nav.move(1)
    XCTAssertEqual(nav.selectedID, "b")
    nav.move(1)
    XCTAssertEqual(nav.selectedID, "b")
  }

  func testReconcilePreservesIdentityAndMovesOffNewlyDisabledRows() {
    var nav = RemotePerformanceNavigation()
    nav.reconcile([.init(id: "a"), .init(id: "b")])
    nav.move(1)
    nav.reconcile([.init(id: "new"), .init(id: "b"), .init(id: "a")])
    XCTAssertEqual(nav.selectedID, "b")
    nav.reconcile([.init(id: "b", enabled: false), .init(id: "a")])
    XCTAssertEqual(nav.selectedID, "a")
    nav.reconcile([])
    XCTAssertNil(nav.selectedID)
  }

  func testChoicesAreExplicitAndReturnToTheirParentWithoutCycling() {
    var nav = RemotePerformanceNavigation()
    nav.reconcile([.init(id: "resolution"), .init(id: "pause")])
    nav.openChoices(for: "resolution", count: 3, selected: 1)
    XCTAssertEqual(nav.choiceIndex, 1)
    nav.move(1)
    XCTAssertEqual(nav.choiceIndex, 2)
    nav.move(1)
    XCTAssertEqual(nav.choiceIndex, 2)
    XCTAssertEqual(nav.selectedID, "resolution")
    nav.cancelChoices()
    XCTAssertNil(nav.choiceIndex)
    XCTAssertEqual(nav.selectedID, "resolution")
  }

  func testChangedOrMissingChoiceParentCannotLeaveStaleSelection() {
    var nav = RemotePerformanceNavigation()
    nav.reconcile([.init(id: "resolution")])
    nav.openChoices(for: "resolution", count: 0, selected: 99)
    XCTAssertNil(nav.choiceIndex)
    nav.openChoices(for: "resolution", count: 3, selected: 99)
    XCTAssertEqual(nav.choiceIndex, 2)
    nav.reconcile([.init(id: "resolution", enabled: false), .init(id: "pause")])
    XCTAssertNil(nav.choiceIndex)
    XCTAssertEqual(nav.selectedID, "pause")
  }
}
