// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// `OnScreenController`: one choice for which controller the on-screen controls are.
final class OnScreenControllerTests: XCTestCase {
  private static let touch = "iOS/4/Touchscreen"
  private static let xbox = "MFi/0/Xbox Wireless Controller"

  private func players(_ bound: [String: String] = [:], wiiExtension: Int = 0, sideways: Bool = false) -> [PlayerState] {
    ControllerHubState.slots(for: .wiiAndGameCube).map { slot in
      let id = (slot.kind == .gameCube ? "gc-" : "wii-") + String(slot.port)
      return PlayerState(
        kind: slot.kind, port: slot.port, deviceQualifier: bound[id] ?? "",
        wiiExtension: slot.kind == .wiiRemote && slot.port == 1 ? wiiExtension : 0,
        isSideways: slot.kind == .wiiRemote && slot.port == 1 && sideways)
    }
  }

  func test_options_areAutoThenEveryControllerOfTheSystem() {
    XCTAssertEqual(OnScreenController.options(for: .gamecube), [.auto, .fixed(.gameCube)])
    XCTAssertEqual(
      OnScreenController.options(for: .wiiAndGameCube),
      [.auto, .fixed(.wiiRemote), .fixed(.wiiNunchuk), .fixed(.wiiClassic), .fixed(.wiiSideways), .fixed(.gameCube)])
    XCTAssertEqual(OnScreenController.auto.title, "Auto")
    XCTAssertEqual(OnScreenController.fixed(.wiiClassic).title, "Wii Remote + Classic Controller")
  }

  func test_current_followsTheDrawnPad_andWiiRemote1() {
    XCTAssertEqual(OnScreenController.current(overlayMode: .auto, players: players(wiiExtension: 2)), .auto)
    XCTAssertEqual(OnScreenController.current(overlayMode: .gamecube, players: players()), .fixed(.gameCube))
    XCTAssertEqual(OnScreenController.current(overlayMode: .wii, players: players(wiiExtension: 1)), .fixed(.wiiNunchuk))
    XCTAssertEqual(OnScreenController.current(overlayMode: .wii, players: players(sideways: true)), .fixed(.wiiSideways))
    XCTAssertEqual(OnScreenController.current(overlayMode: .wii, players: []), .fixed(.wiiRemote), "no Wii Remote listed: a plain one")
  }

  func test_plan_auto_onlyStoresTheMode() {
    XCTAssertEqual(OnScreenControllerPlan.steps(for: .auto, players: players(["wii-1": Self.touch])), [.setOverlayMode(.auto)])
  }

  /// The case that took three steps before: a Wii game that wants the on-screen GameCube pad.
  func test_plan_gameCube_bindsPlayer1_thenDrawsTheGameCubePad() {
    XCTAssertEqual(
      OnScreenControllerPlan.steps(for: .fixed(.gameCube), players: players(["wii-1": Self.touch])),
      [.bindTouchscreen(PlayerSlot(kind: .gameCube, port: 1)), .setOverlayMode(.gamecube)])
  }

  func test_plan_skipsTheBinding_whenTheTouchscreenAlreadyHoldsThatPort() {
    XCTAssertEqual(
      OnScreenControllerPlan.steps(for: .fixed(.gameCube), players: players(["gc-1": "iOS/0/Touchscreen"])),
      [.setOverlayMode(.gamecube)])
  }

  func test_plan_wiiVariant_bindsWiiRemote1_setsExtensionAndSideways_thenDrawsTheWiiPad() {
    XCTAssertEqual(
      OnScreenControllerPlan.steps(for: .fixed(.wiiClassic), players: players(["wii-1": Self.xbox])),
      [.bindTouchscreen(PlayerSlot(kind: .wiiRemote, port: 1)), .setExtension(wiimote: 1, value: 2),
       .setSideways(wiimote: 1, enabled: false), .setOverlayMode(.wii)])
    XCTAssertEqual(
      OnScreenControllerPlan.steps(for: .fixed(.wiiSideways), players: players(["wii-1": Self.touch])),
      [.setExtension(wiimote: 1, value: 0), .setSideways(wiimote: 1, enabled: true), .setOverlayMode(.wii)])
  }
}
