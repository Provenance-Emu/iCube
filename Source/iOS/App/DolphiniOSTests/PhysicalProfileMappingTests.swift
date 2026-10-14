// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import GameController
import XCTest
@testable import iCube

/// The physical-profile adapter for pads the system exposes without an extended gamepad:
/// the shared C++ mapping through `PhysicalProfileBridge`, and the synthesized elements.
final class PhysicalProfileMappingTests: XCTestCase {
  // MARK: Mapping

  private func bindings(_ names: [String], n64: Bool = false) -> [String: String] {
    PhysicalProfileBridge.bindings(forElementNames: names, isN64Pad: n64)
  }

  func testN64PadIsRecognisedByVendorName() {
    XCTAssertTrue(PhysicalProfileBridge.isN64Pad(withVendorName: "N64 Controller", productCategory: "HID"))
    XCTAssertTrue(PhysicalProfileBridge.isN64Pad(withVendorName: nil, productCategory: "Nintendo N64"))
    XCTAssertFalse(PhysicalProfileBridge.isN64Pad(withVendorName: "DualSense Wireless Controller", productCategory: "DualSense"))
    XCTAssertFalse(PhysicalProfileBridge.isN64Pad(withVendorName: nil, productCategory: nil))
  }

  func testStandardFrameworkNamesMapToTheirInputs() {
    let result = bindings([
      "Button A", "Button B", "Button X", "Button Y", "Direction Pad", "Left Thumbstick", "Right Thumbstick",
      "Left Shoulder", "Right Shoulder", "Left Trigger", "Right Trigger", "Button Menu", "Button Options", "Button Home",
    ])
    XCTAssertEqual(result["Button A"], "Button A")
    XCTAssertEqual(result["Button B"], "Button B")
    XCTAssertEqual(result["Direction Pad"], "D-Pad")
    XCTAssertEqual(result["Left Thumbstick"], "L Stick")
    XCTAssertEqual(result["Right Thumbstick"], "R Stick")
    XCTAssertEqual(result["Left Shoulder"], "L Shoulder")
    XCTAssertEqual(result["Right Trigger"], "R Trigger")
    XCTAssertEqual(result["Button Menu"], "Menu")
    XCTAssertEqual(result["Button Options"], "Options")
    XCTAssertEqual(result["Button Home"], "Home")
  }

  /// The N64 pad's printed labels, with GameCube semantics: C cluster = C-Stick, Z = GameCube Z
  /// (`R Shoulder`, what the default GCPad profile binds Buttons/Z to), L / R = analog triggers.
  func testN64LabelsUseGameCubeSemantics() {
    let result = bindings([
      "A", "B", "C Up", "C Down", "C Left", "C Right", "Z", "L", "R", "ZR", "Start", "Home", "Direction Pad", "Joystick",
    ], n64: true)
    XCTAssertEqual(result["A"], "Button A")
    XCTAssertEqual(result["B"], "Button B")
    XCTAssertEqual(result["C Up"], "R Stick Y+")
    XCTAssertEqual(result["C Down"], "R Stick Y-")
    XCTAssertEqual(result["C Left"], "R Stick X-")
    XCTAssertEqual(result["C Right"], "R Stick X+")
    XCTAssertEqual(result["Z"], "R Shoulder")
    XCTAssertEqual(result["L"], "L Trigger")
    XCTAssertEqual(result["R"], "R Trigger")
    XCTAssertEqual(result["ZR"], "Options")
    XCTAssertEqual(result["Start"], "Menu")
    XCTAssertEqual(result["Home"], "Home")
    XCTAssertEqual(result["Joystick"], "L Stick")
  }

  /// Bare "Button <n>" names resolve through RetroArch's N64_Nintendo_Switch_Online.cfg indices,
  /// and only for the N64 pad.
  func testBareButtonNumbersFollowTheRetroArchAutoconfigForTheN64PadOnly() {
    let names = (0 ... 12).map { "Button \($0)" } + ["Direction Pad", "Left Thumbstick"]
    let n64 = bindings(names, n64: true)
    XCTAssertEqual(n64["Button 0"], "Button B")
    XCTAssertEqual(n64["Button 1"], "Button A")
    XCTAssertEqual(n64["Button 2"], "R Stick Y+")
    XCTAssertEqual(n64["Button 3"], "R Stick X-")
    XCTAssertEqual(n64["Button 4"], "L Trigger")
    XCTAssertEqual(n64["Button 5"], "R Trigger")
    XCTAssertEqual(n64["Button 6"], "R Shoulder")
    XCTAssertEqual(n64["Button 7"], "R Stick Y-")
    XCTAssertEqual(n64["Button 8"], "R Stick X+")
    XCTAssertEqual(n64["Button 9"], "Menu")
    XCTAssertEqual(n64["Button 10"], "Options")
    XCTAssertNil(n64["Button 11"])
    XCTAssertEqual(n64["Button 12"], "Home")

    XCTAssertTrue(bindings(names, n64: false).isEmpty, "numbers mean nothing on another pad, so it is unusable")
  }

  func testNamesAreNormalisedBeforeLookup() {
    let result = bindings(["BUTTON_A", "c-up", "  Direction   Pad ", "button start"], n64: true)
    XCTAssertEqual(result["BUTTON_A"], "Button A")
    XCTAssertEqual(result["c-up"], "R Stick Y+")
    XCTAssertEqual(result["  Direction   Pad "], "D-Pad")
    XCTAssertEqual(result["button start"], "Menu")
  }

  func testStandardNamesWinOverAliasesForTheSameInput() {
    // "A" (alias) and "Button A" (standard) both want Button A; the standard one is bound.
    let result = bindings(["A", "Button A", "Direction Pad"])
    XCTAssertEqual(result["Button A"], "Button A")
    XCTAssertNil(result["A"])
  }

  func testUnusableProfilesProduceNoBindings() {
    XCTAssertTrue(bindings(["Button A", "Button B"]).isEmpty, "no direction input")
    XCTAssertTrue(bindings(["Direction Pad", "Button Menu"]).isEmpty, "no face button")
    XCTAssertFalse(bindings(["Direction Pad", "Button A"]).isEmpty)
    XCTAssertFalse(bindings(["Left Thumbstick", "B"]).isEmpty)
  }

  func testEveryBridgeOutputIsASynthesizedInput() {
    let names = (0 ... 12).map { "Button \($0)" } + [
      "Direction Pad", "Left Thumbstick", "Right Thumbstick", "Left Shoulder", "Right Shoulder",
      "Left Trigger", "Right Trigger", "Button X", "Button Y", "Button Menu", "Button Options", "Button Home",
    ]
    for value in bindings(names, n64: true).values {
      XCTAssertNotNil(SynthesizedInput(rawValue: value), "bridge returned '\(value)', which the Swift side does not know")
    }
  }

  // MARK: Synthesized elements

  func testButtonUpdateFiresPressedThenValueHandlers() {
    let button = SynthesizedButtonInput()
    var events: [String] = []
    button.pressedChangedHandler = { _, value, pressed in events.append("pressed \(pressed) \(value)") }
    button.valueChangedHandler = { _, value, pressed in events.append("value \(pressed) \(value)") }

    button.update(value: 1, pressed: true)
    XCTAssertTrue(button.isPressed)
    XCTAssertEqual(button.value, 1)
    XCTAssertEqual(events, ["pressed true 1.0", "value true 1.0"])

    events.removeAll()
    button.update(value: 1, pressed: true)
    XCTAssertTrue(events.isEmpty, "no change, no callbacks")

    button.update(value: 0, pressed: false)
    XCTAssertFalse(button.isPressed)
    XCTAssertEqual(events, ["pressed false 0.0", "value false 0.0"])
  }

  func testDirectionPadUpdateSetsAxesAndDigitalDirections() {
    let pad = SynthesizedDirectionPad()
    var reported: (Float, Float)?
    pad.valueChangedHandler = { _, x, y in reported = (x, y) }

    pad.update(x: -1, y: 0.75)
    XCTAssertEqual(pad.xAxis.value, -1)
    XCTAssertEqual(pad.yAxis.value, 0.75)
    XCTAssertTrue(pad.left.isPressed)
    XCTAssertTrue(pad.up.isPressed)
    XCTAssertFalse(pad.right.isPressed)
    XCTAssertFalse(pad.down.isPressed)
    XCTAssertEqual(reported?.0, -1)
    XCTAssertEqual(reported?.1, 0.75)

    pad.update(x: 0.2, y: -0.2)
    XCTAssertFalse(pad.left.isPressed, "below the digital threshold")
    XCTAssertFalse(pad.down.isPressed)
  }

  func testOptionalButtonsAreReportedOnlyWhenThePadHasThem() {
    let gamepad = SynthesizedGamepad()
    XCTAssertNil(gamepad.buttonOptions)
    XCTAssertNil(gamepad.buttonHome)
    XCTAssertNil(gamepad.leftThumbstickButton)
    gamepad.hasOptions = true
    gamepad.hasHome = true
    XCTAssertNotNil(gamepad.buttonOptions)
    XCTAssertNotNil(gamepad.buttonHome)
  }

  func testGamepadElementsResolveByInputAndNotifyWholeGamepadObservers() {
    let gamepad = SynthesizedGamepad()
    var changed: [GCControllerElement] = []
    gamepad.valueChangedHandler = { _, element in changed.append(element) }

    XCTAssertTrue(gamepad.button(for: .buttonA) === gamepad.buttonA)
    XCTAssertTrue(gamepad.button(for: .menu) === gamepad.buttonMenu)
    XCTAssertTrue(gamepad.pad(for: .rightThumbstick) === gamepad.rightThumbstick)
    XCTAssertNil(gamepad.button(for: .dpad))
    XCTAssertNil(gamepad.pad(for: .rightStickUp))

    gamepad.synthesizedButtonA.update(value: 1, pressed: true)
    gamepad.notify(gamepad.buttonA)
    XCTAssertTrue(changed.first === gamepad.buttonA)
  }

  func testSynthesizedInputClassification() {
    XCTAssertTrue(SynthesizedInput.rightStickUp.isCButton)
    XCTAssertFalse(SynthesizedInput.rightThumbstick.isCButton)
    XCTAssertTrue(SynthesizedInput.dpad.isDirection)
    XCTAssertFalse(SynthesizedInput.buttonA.isDirection)
  }
}
