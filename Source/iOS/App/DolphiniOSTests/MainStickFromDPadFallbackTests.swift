// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

/// A GameCube profile written for a pad with a left stick, loaded for a pad that has only a D-pad.
final class MainStickFromDPadFallbackTests: XCTestCase {
  /// The directional lines of `Data/Sys/Profiles/GCPad/Physical Controller.ini`.
  private let physicalController = [
    "Buttons/A": "`Button A`",
    "D-Pad/Up": "`D-Pad Up`", "D-Pad/Down": "`D-Pad Down`", "D-Pad/Left": "`D-Pad Left`", "D-Pad/Right": "`D-Pad Right`",
    "Main Stick/Up": "`L Stick Y+`", "Main Stick/Down": "`L Stick Y-`",
    "Main Stick/Left": "`L Stick X-`", "Main Stick/Right": "`L Stick X+`",
    "C-Stick/Up": "`R Stick Y+`",
  ]
  private let dpad = ["D-Pad Up", "D-Pad Down", "D-Pad Left", "D-Pad Right"]
  private let leftStick = ["L Stick X+", "L Stick X-", "L Stick Y+", "L Stick Y-"]

  private func fallback(_ profile: [String: String], inputs: [String]) -> [String: String] {
    TVControllerMappingBridge.mainStickFromDPadFallback(forProfile: profile, inputNames: inputs)
  }

  func testDPadOnlyPadSteersWithItsDPad() {
    let changes = fallback(physicalController, inputs: dpad + ["Button A", "Button B", "Menu"])
    XCTAssertEqual(changes, [
      "Main Stick/Up": "`D-Pad Up`", "Main Stick/Down": "`D-Pad Down`",
      "Main Stick/Left": "`D-Pad Left`", "Main Stick/Right": "`D-Pad Right`",
      "D-Pad/Up": "", "D-Pad/Down": "", "D-Pad/Left": "", "D-Pad/Right": "",
    ])
  }

  func testPadWithALeftStickIsLeftAlone() {
    XCTAssertTrue(fallback(physicalController, inputs: dpad + leftStick).isEmpty)
    XCTAssertTrue(fallback(physicalController, inputs: dpad + ["L Stick X+"]).isEmpty, "any left-stick input counts")
  }

  func testPadWithoutAFullDPadIsLeftAlone() {
    XCTAssertTrue(fallback(physicalController, inputs: ["Button A"]).isEmpty)
    XCTAssertTrue(fallback(physicalController, inputs: ["D-Pad Up", "D-Pad Down", "D-Pad Left"]).isEmpty)
  }

  /// Only the untouched default binding moves: a Main Stick the player mapped stays as written.
  func testAMainStickThePlayerMappedIsNeverRewritten() {
    var custom = physicalController
    custom["Main Stick/Up"] = "`Button X`"
    XCTAssertTrue(fallback(custom, inputs: dpad).isEmpty)
    var unbound = physicalController
    unbound["Main Stick/Left"] = nil
    XCTAssertTrue(fallback(unbound, inputs: dpad).isEmpty)
  }

  /// A D-pad line the player gave another job keeps it; only a line that would double the press is cleared.
  func testOnlyADPadLineThatWouldDoubleThePressIsCleared() {
    var custom = physicalController
    custom["D-Pad/Up"] = "`Button Y`"
    custom["D-Pad/Left"] = nil
    let changes = fallback(custom, inputs: dpad)
    XCTAssertEqual(changes["Main Stick/Up"], "`D-Pad Up`")
    XCTAssertNil(changes["D-Pad/Up"])
    XCTAssertNil(changes["D-Pad/Left"])
    XCTAssertEqual(changes["D-Pad/Down"], "")
  }

  /// A Wii Remote profile has no Main Stick, so it is never changed.
  func testWiiProfileIsNeverChanged() {
    let wii = ["D-Pad/Up": "`D-Pad Up`", "Nunchuk/Stick/Up": "`L Stick Y+`", "Buttons/A": "`Button A`"]
    XCTAssertTrue(fallback(wii, inputs: dpad).isEmpty)
  }

  func testValuesAreComparedWithoutSurroundingSpaces() {
    var spaced = physicalController
    spaced["Main Stick/Up"] = "  `L Stick Y+` "
    XCTAssertEqual(fallback(spaced, inputs: dpad)["Main Stick/Up"], "`D-Pad Up`")
  }
}
