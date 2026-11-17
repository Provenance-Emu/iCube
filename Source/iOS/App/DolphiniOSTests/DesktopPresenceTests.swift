// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class DesktopPresenceTests: XCTestCase {
  func testStaysInMenuBarOnlyWhenAskedAndNoGameIsRunning() {
    XCTAssertEqual(DesktopPresence.afterLastWindowCloses(keepRunning: true, gameRunning: false, hasMenuBarItem: true), .stayInMenuBar)
    XCTAssertEqual(DesktopPresence.afterLastWindowCloses(keepRunning: false, gameRunning: false, hasMenuBarItem: true), .quit)
  }

  func testRunningGameEndsWithItsWindow() {
    XCTAssertEqual(DesktopPresence.afterLastWindowCloses(keepRunning: true, gameRunning: true, hasMenuBarItem: true), .quit)
  }

  func testQuitsWhenThereIsNoMenuBarItemToComeBackThrough() {
    XCTAssertEqual(DesktopPresence.afterLastWindowCloses(keepRunning: true, gameRunning: false, hasMenuBarItem: false), .quit)
  }

  func testBackgroundActivityFollowsLibrarySharing() {
    XCTAssertTrue(DesktopPresence.needsBackgroundActivity(sharingLibrary: true))
    XCTAssertFalse(DesktopPresence.needsBackgroundActivity(sharingLibrary: false))
  }

  func testMenuChecksReflectTheTwoSwitches() {
    for (sharing, keepRunning) in [(true, true), (true, false), (false, true), (false, false)] {
      let rows = DesktopPresence.menu(sharingLibrary: sharing, keepRunning: keepRunning)
      XCTAssertEqual(checked(.toggleSharing, in: rows), sharing)
      XCTAssertEqual(checked(.toggleKeepRunning, in: rows), keepRunning)
      XCTAssertEqual(checked(.openWindow, in: rows), false)
      XCTAssertEqual(checked(.quit, in: rows), false)
    }
  }

  func testMenuOpensFirstQuitsLastAndStatesSharingInWords() {
    let on = DesktopPresence.menu(sharingLibrary: true, keepRunning: true)
    let off = DesktopPresence.menu(sharingLibrary: false, keepRunning: true)
    XCTAssertEqual(actions(in: on), [.openWindow, .toggleSharing, .toggleKeepRunning, .quit])
    XCTAssertEqual(statusLines(in: on).count, 1)
    XCTAssertEqual(statusLines(in: off).count, 1)
    XCTAssertNotEqual(statusLines(in: on), statusLines(in: off))
  }

  private func actions(in rows: [DesktopPresence.MenuRow]) -> [DesktopPresence.MenuAction] {
    rows.compactMap { if case .action(let action, _, _) = $0 { return action } else { return nil } }
  }

  private func statusLines(in rows: [DesktopPresence.MenuRow]) -> [String] {
    rows.compactMap { if case .status(let text) = $0 { return text } else { return nil } }
  }

  private func checked(_ wanted: DesktopPresence.MenuAction, in rows: [DesktopPresence.MenuRow]) -> Bool? {
    for case .action(let action, _, let checked) in rows where action == wanted { return checked }
    return nil
  }
}
