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

  // MARK: Stick clicks

  func testStickClicksResolveByStandardNameAndAlias() {
    let standard = bindings(["Direction Pad", "Button A", "Left Thumbstick", "Left Thumbstick Button", "Right Thumbstick Button"])
    XCTAssertEqual(standard["Left Thumbstick"], "L Stick")
    XCTAssertEqual(standard["Left Thumbstick Button"], "L Stick Button")
    XCTAssertEqual(standard["Right Thumbstick Button"], "R Stick Button")

    let aliases = bindings(["Direction Pad", "Button A", "L3", "Button R3"])
    XCTAssertEqual(aliases["L3"], "L Stick Button")
    XCTAssertEqual(aliases["Button R3"], "R Stick Button")
  }

  func testSynthesizedGamepadReportsStickClicksOnlyWhenThePadHasThem() {
    let gamepad = SynthesizedGamepad()
    XCTAssertNil(gamepad.leftThumbstickButton)
    XCTAssertNil(gamepad.rightThumbstickButton)
    gamepad.hasLeftThumbstickButton = true
    XCTAssertTrue(gamepad.leftThumbstickButton === gamepad.button(for: .leftThumbstickButton))
    XCTAssertNil(gamepad.rightThumbstickButton)
    gamepad.hasRightThumbstickButton = true
    XCTAssertTrue(gamepad.rightThumbstickButton === gamepad.button(for: .rightThumbstickButton))
    XCTAssertFalse(SynthesizedInput.leftThumbstickButton.isDirection)
  }

  // MARK: Generic HID pads

  private func generic(buttons: [String], directions: [String], axes: [String] = [],
                       category: String = "HID") -> [String: SynthesizedInput] {
    PhysicalProfileController.resolveBindings(
      buttonNames: buttons, directionNames: directions, axisNames: axes, vendorName: nil, productCategory: category)
  }

  func testNumberedButtonsAndAnUnnamedDirectionFillInputsInOrder() {
    let result = generic(buttons: (1 ... 13).map { "Button \($0)" }, directions: ["Hat Switch"])
    XCTAssertEqual(result["Hat Switch"], .dpad)
    XCTAssertEqual(result["Button 1"], .buttonA)
    XCTAssertEqual(result["Button 2"], .buttonB)
    XCTAssertEqual(result["Button 3"], .buttonX)
    XCTAssertEqual(result["Button 4"], .buttonY)
    XCTAssertEqual(result["Button 5"], .leftShoulder)
    XCTAssertEqual(result["Button 6"], .rightShoulder)
    XCTAssertEqual(result["Button 7"], .leftTrigger)
    XCTAssertEqual(result["Button 8"], .rightTrigger)
    XCTAssertEqual(result["Button 9"], .options)
    XCTAssertEqual(result["Button 10"], .menu)
    XCTAssertEqual(result["Button 11"], .leftThumbstickButton)
    XCTAssertEqual(result["Button 12"], .rightThumbstickButton)
    XCTAssertNil(result["Button 13"])
  }

  func testLeftoverDirectionElementsFillDpadThenSticks() {
    let result = generic(buttons: ["Button 0", "Button 1"], directions: ["Axis Pair 2", "Axis Pair 1", "Hat Switch"])
    XCTAssertEqual(result["Axis Pair 1"], .dpad)
    XCTAssertEqual(result["Axis Pair 2"], .leftThumbstick)
    XCTAssertEqual(result["Hat Switch"], .rightThumbstick)
    XCTAssertEqual(result["Button 0"], .buttonA)
  }

  /// Names that differ only in a trailing number go by that number, not "1, 10, 11, 2".
  func testButtonsNamedWithAPrefixAndANumberKeepTheirNumericOrder() {
    let result = generic(buttons: (1 ... 12).map { "Generic Button \($0)" }, directions: ["Hat Switch"])
    XCTAssertEqual(result["Generic Button 1"], .buttonA)
    XCTAssertEqual(result["Generic Button 2"], .buttonB)
    XCTAssertEqual(result["Generic Button 9"], .options)
    XCTAssertEqual(result["Generic Button 10"], .menu)
    XCTAssertEqual(result["Generic Button 12"], .rightThumbstickButton)

    let sticks = generic(buttons: ["Button 1"], directions: ["Axis Pair 10", "Axis Pair 2"])
    XCTAssertEqual(sticks["Axis Pair 2"], .dpad)
    XCTAssertEqual(sticks["Axis Pair 10"], .leftThumbstick)
  }

  /// A profile can list one element twice. It is reduced to one name before resolving, so the
  /// alias neither takes a positional slot nor displaces the standard name.
  func testAnAliasedElementIsResolvedByItsBestName() {
    XCTAssertEqual(PhysicalProfileBridge.preferredName(amongAliases: ["Button 1", "Button A"]), "Button A")
    XCTAssertEqual(PhysicalProfileBridge.preferredName(amongAliases: ["Button 7", "L2"]), "L2")
    XCTAssertEqual(PhysicalProfileBridge.preferredName(amongAliases: ["Button 10", "Button 2"]), "Button 2")
    XCTAssertEqual(PhysicalProfileBridge.preferredName(amongAliases: ["Fire"]), "Fire")

    // "Button A" and "Button 1" are one element: with the alias dropped, "Button 2" is B.
    let names = [["Button A", "Button 1"], ["Button 2"], ["Button 3"]]
      .map { PhysicalProfileBridge.preferredName(amongAliases: $0) }
    let result = generic(buttons: names, directions: ["Direction Pad"])
    XCTAssertEqual(result["Button A"], .buttonA)
    XCTAssertEqual(result["Button 2"], .buttonB)
    XCTAssertEqual(result["Button 3"], .buttonX)
  }

  func testNamedElementsKeepTheirInputAndDirectionHalvesAreNotButtons() {
    let result = generic(
      buttons: ["Button A", "Button B", "Button Menu", "Direction Pad Up", "Direction Pad Left",
                "Left Thumbstick Button", "Button Share"],
      directions: ["Direction Pad", "Left Thumbstick"])
    XCTAssertEqual(result["Button A"], .buttonA)
    XCTAssertEqual(result["Direction Pad"], .dpad)
    XCTAssertEqual(result["Left Thumbstick"], .leftThumbstick)
    XCTAssertNil(result["Direction Pad Up"])
    XCTAssertNil(result["Direction Pad Left"])
    XCTAssertEqual(result["Left Thumbstick Button"], .leftThumbstickButton)
    XCTAssertNil(result["Button Share"], "a named extra is left alone once the names gave a face button")
  }

  func testDirectionHalvesAreNeverTakenByPosition() {
    // No face button by name, so oddly named buttons are taken, but never a half of a direction element.
    let result = generic(buttons: ["Hat Switch Up", "Hat Switch Down", "Fire"], directions: ["Hat Switch"])
    XCTAssertEqual(result, ["Hat Switch": .dpad, "Fire": .buttonA])
  }

  func testOddlyNamedButtonsAreTakenWhenNamesGiveNoFaceButton() {
    let result = generic(buttons: ["Fire", "Jump"], directions: ["Direction Pad"])
    XCTAssertEqual(Set(result.values), [.dpad, .buttonA, .buttonB])
  }

  func testNumberedButtonsFillOnlyTheInputsNamesLeftFree() {
    let result = generic(buttons: ["Button A", "Button B", "Left Shoulder", "Button 14", "Button 15"],
                         directions: ["Direction Pad"])
    XCTAssertEqual(result["Button 14"], .buttonX)
    XCTAssertEqual(result["Button 15"], .buttonY)
    XCTAssertEqual(result["Left Shoulder"], .leftShoulder)
  }

  /// On a generic pad L / R are the shoulders and ZL / ZR the triggers; on the N64 pad L / R are the
  /// GameCube analog triggers and ZR is Options.
  func testPrintedShoulderLabelsFollowAModernPadOnAGenericPad() {
    let result = generic(buttons: ["A", "L", "R", "ZL", "ZR"], directions: ["Direction Pad"])
    XCTAssertEqual(result["L"], .leftShoulder)
    XCTAssertEqual(result["R"], .rightShoulder)
    XCTAssertEqual(result["ZL"], .leftTrigger)
    XCTAssertEqual(result["ZR"], .rightTrigger)

    let n64 = PhysicalProfileController.resolveBindings(
      buttonNames: ["A", "L", "R", "ZR"], directionNames: ["Direction Pad"], vendorName: "N64 Controller",
      productCategory: "HID")
    XCTAssertEqual(n64["L"], .leftTrigger)
    XCTAssertEqual(n64["ZR"], .options)
  }

  func testAButtonNeverTakesADirectionInputByName() {
    // A button called "Hat" must not leave the pad without its real D-pad.
    let result = generic(buttons: ["Hat", "Button 1"], directions: ["Axis Pair"])
    XCTAssertEqual(result["Axis Pair"], .dpad)
    XCTAssertNotEqual(result["Hat"], .dpad)
  }

  func testATriggerAxisTakesTheTriggerOnlyWhenNoButtonDid() {
    let named = generic(buttons: ["Button A", "Button B"], directions: ["Direction Pad"],
                        axes: ["Left Trigger", "R2", "Left Thumbstick X Axis"])
    XCTAssertEqual(named["Left Trigger"], .leftTrigger)
    XCTAssertEqual(named["R2"], .rightTrigger)
    XCTAssertNil(named["Left Thumbstick X Axis"])

    // Eight numbered buttons already cover the triggers; the axes are left alone.
    let numbered = generic(buttons: (1 ... 10).map { "Button \($0)" }, directions: ["Hat Switch"],
                           axes: ["Left Trigger", "Right Trigger"])
    XCTAssertEqual(numbered["Button 7"], .leftTrigger)
    XCTAssertNil(numbered["Left Trigger"])
    XCTAssertEqual(numbered["Button 10"], .menu)
  }

  func testGenericPadWithoutAFaceButtonOrDirectionIsUnusable() {
    XCTAssertTrue(generic(buttons: ["Button 1", "Button 2"], directions: []).isEmpty, "no direction input")
    XCTAssertTrue(generic(buttons: [], directions: ["Hat Switch"]).isEmpty, "no button")
  }

  /// A remote is bound by name alone, never by position, and never wrapped.
  func testRemotesAreNotBoundByPosition() {
    XCTAssertTrue(PhysicalProfileBridge.isRemoteProductCategory("Siri Remote (2nd Generation)"))
    XCTAssertTrue(PhysicalProfileBridge.isRemoteProductCategory("Control Center Remote"))
    XCTAssertFalse(PhysicalProfileBridge.isRemoteProductCategory("HID"))
    XCTAssertFalse(PhysicalProfileBridge.isRemoteProductCategory(nil))
    XCTAssertTrue(generic(buttons: ["Button 1", "Button 2"], directions: ["Touch Surface"], category: "Some Remote").isEmpty)
    XCTAssertFalse(generic(buttons: ["Button 1", "Button 2"], directions: ["Touch Surface"]).isEmpty)
  }

  func testGenericPadWithNoMicroGamepadIsWrappedAndPausesFromOptions() {
    let result = generic(buttons: (1 ... 12).map { "Button \($0)" }, directions: ["Hat Switch"])
    XCTAssertTrue(PhysicalProfileController.shouldWrap(
      hasExtendedGamepad: false, hasMicroGamepad: false, isMenuRemote: false, isSwitchOnlinePad: false, bindings: result))
    XCTAssertEqual(PhysicalProfileController.pauseTrigger(for: result, isSnesPad: false), .standard)
  }

  func testEveryGenericBridgeOutputIsASynthesizedInput() {
    let raw = PhysicalProfileBridge.bindings(
      forVendorName: nil, productCategory: "HID", buttonNames: (1 ... 12).map { "Button \($0)" },
      directionNames: ["Hat Switch", "Stick 1", "Stick 2"], axisNames: [])
    XCTAssertEqual(raw.count, 15)
    for value in raw.values {
      XCTAssertNotNil(SynthesizedInput(rawValue: value), "bridge returned '\(value)', which the Swift side does not know")
    }
  }

  // MARK: Trigger axes

  func testTriggerAxisRestingAtZeroIsReadAsIs() {
    var rests: ObjCBool = false
    XCTAssertEqual(PhysicalProfileBridge.triggerValue(forAxisValue: 0, restsAtMinusOne: &rests), 0)
    XCTAssertEqual(PhysicalProfileBridge.triggerValue(forAxisValue: 0.5, restsAtMinusOne: &rests), 0.5)
    XCTAssertEqual(PhysicalProfileBridge.triggerValue(forAxisValue: 1, restsAtMinusOne: &rests), 1)
    XCTAssertEqual(PhysicalProfileBridge.triggerValue(forAxisValue: -0.02, restsAtMinusOne: &rests), 0, "noise around rest")
    XCTAssertFalse(rests.boolValue)
  }

  func testTriggerAxisRestingAtMinusOneIsRescaled() {
    var rests: ObjCBool = false
    XCTAssertEqual(PhysicalProfileBridge.triggerValue(forAxisValue: -1, restsAtMinusOne: &rests), 0)
    XCTAssertTrue(rests.boolValue)
    XCTAssertEqual(PhysicalProfileBridge.triggerValue(forAxisValue: 0, restsAtMinusOne: &rests), 0.5, "half pulled, once known")
    XCTAssertEqual(PhysicalProfileBridge.triggerValue(forAxisValue: 1, restsAtMinusOne: &rests), 1)
    XCTAssertEqual(PhysicalProfileBridge.triggerValue(forAxisValue: -1, restsAtMinusOne: &rests), 0)
  }

  // MARK: Unnamed pads

  func testUnnamedPadIsNamedByItsProductCategory() {
    XCTAssertEqual(PhysicalProfileBridge.fallbackName(forProductCategory: "HID"), "HID Gamepad")
    XCTAssertEqual(PhysicalProfileBridge.fallbackName(forProductCategory: ""), "Unknown Controller")
    XCTAssertEqual(PhysicalProfileBridge.fallbackName(forProductCategory: nil), "Unknown Controller")
  }

  // MARK: Switch Online SNES pad

  /// The nine elements Apple's `_GCNintendoSuperFamicomControllerProfile` describes. There is no
  /// Home, ZL or ZR.
  private let snesElementNames = [
    "Button A", "Button B", "Button X", "Button Y", "Left Shoulder", "Right Shoulder",
    "Button Menu", "Button Options", "Direction Pad",
  ]

  private func snesBindings() -> [String: SynthesizedInput] {
    PhysicalProfileController.resolveBindings(
      elementNames: snesElementNames, vendorName: "SNES Controller", productCategory: "Switch SNES Controller")
  }

  func testSnesPadIsRecognisedAsASwitchOnlinePad() {
    XCTAssertTrue(PhysicalProfileBridge.isSnesPad(withVendorName: "SNES Controller", productCategory: "Switch SNES Controller"))
    XCTAssertTrue(PhysicalProfileBridge.isSnesPad(withVendorName: nil, productCategory: "Super Famicom Controller"))
    XCTAssertFalse(PhysicalProfileBridge.isSnesPad(withVendorName: "N64 Controller", productCategory: "HID"))
    XCTAssertFalse(PhysicalProfileBridge.isSnesPad(withVendorName: "Pro Controller", productCategory: "Switch Pro Controller"))

    XCTAssertTrue(PhysicalProfileBridge.isSwitchOnlinePad(withVendorName: "SNES Controller", productCategory: "Switch SNES Controller"))
    XCTAssertTrue(PhysicalProfileBridge.isSwitchOnlinePad(withVendorName: "N64 Controller", productCategory: "HID"))
    XCTAssertFalse(PhysicalProfileBridge.isSwitchOnlinePad(withVendorName: "Remote", productCategory: "Siri Remote (2nd Generation)"))
    XCTAssertFalse(PhysicalProfileBridge.isSwitchOnlinePad(withVendorName: nil, productCategory: nil))
  }

  /// Start is "Button Menu" (GameCube Start / Wii +, the `Menu` input every profile binds) and
  /// Select is "Button Options". Face buttons keep the MFi positional names: "Button A" is the
  /// bottom button (SNES B), as on every other MFi pad.
  func testSnesProfileBindsStartAndSelect() {
    let result = snesBindings()
    XCTAssertEqual(result.count, snesElementNames.count, "every element is bound")
    XCTAssertEqual(result["Button Menu"], .menu)
    XCTAssertEqual(result["Button Options"], .options)
    XCTAssertEqual(result["Button A"], .buttonA)
    XCTAssertEqual(result["Button B"], .buttonB)
    XCTAssertEqual(result["Button X"], .buttonX)
    XCTAssertEqual(result["Button Y"], .buttonY)
    XCTAssertEqual(result["Left Shoulder"], .leftShoulder)
    XCTAssertEqual(result["Right Shoulder"], .rightShoulder)
    XCTAssertEqual(result["Direction Pad"], .dpad)
  }

  func testSnesPadIsWrappedDespiteItsMicroGamepad() {
    XCTAssertTrue(PhysicalProfileController.shouldWrap(
      hasExtendedGamepad: false, hasMicroGamepad: true, isMenuRemote: false, isSwitchOnlinePad: true,
      bindings: snesBindings()))
  }

  func testWrapGateKeepsEveryOtherShapeAsItWas() {
    let bindings = snesBindings()
    // N64 pad on tvOS 17: no extended or micro gamepad.
    XCTAssertTrue(PhysicalProfileController.shouldWrap(
      hasExtendedGamepad: false, hasMicroGamepad: false, isMenuRemote: false, isSwitchOnlinePad: true, bindings: bindings))
    // Siri Remote: micro only, a remote. Its profile has a direction pad and Button A, so the
    // bindings alone would pass; a wrapper would turn it into a player.
    let remote = PhysicalProfileController.resolveBindings(
      elementNames: ["Direction Pad", "Button A", "Button X", "Button Menu"], vendorName: "Remote",
      productCategory: "Siri Remote (2nd Generation)")
    XCTAssertFalse(remote.isEmpty)
    XCTAssertFalse(PhysicalProfileController.shouldWrap(
      hasExtendedGamepad: false, hasMicroGamepad: true, isMenuRemote: true, isSwitchOnlinePad: false, bindings: remote))
    XCTAssertFalse(PhysicalProfileController.shouldWrap(
      hasExtendedGamepad: false, hasMicroGamepad: true, isMenuRemote: true, isSwitchOnlinePad: true, bindings: remote),
      "a remote is never wrapped")
    // Another micro-gamepad pad that is not a Switch Online pad keeps the system's profiles.
    XCTAssertFalse(PhysicalProfileController.shouldWrap(
      hasExtendedGamepad: false, hasMicroGamepad: true, isMenuRemote: false, isSwitchOnlinePad: false, bindings: bindings))
    // An extended gamepad is never wrapped.
    XCTAssertFalse(PhysicalProfileController.shouldWrap(
      hasExtendedGamepad: true, hasMicroGamepad: true, isMenuRemote: false, isSwitchOnlinePad: true, bindings: bindings))
    // Nothing usable to synthesize from.
    XCTAssertFalse(PhysicalProfileController.shouldWrap(
      hasExtendedGamepad: false, hasMicroGamepad: true, isMenuRemote: false, isSwitchOnlinePad: true, bindings: [:]))
  }

  // MARK: Pause trigger

  func testSnesPadPausesFromSelectAndStart() {
    XCTAssertEqual(PhysicalProfileController.pauseTrigger(for: snesBindings(), isSnesPad: true), .selectStartChord)
  }

  func testN64PadKeepsItsPauseRoutes() {
    let withHome = bindings(["A", "B", "Start", "ZR", "Home", "Direction Pad"], n64: true)
      .compactMapValues { SynthesizedInput(rawValue: $0) }
    XCTAssertEqual(PhysicalProfileController.pauseTrigger(for: withHome, isSnesPad: false), .home)
    // Whether Apple's N64 description has Home is unconfirmed; without it ZR (Options) still
    // pauses on its own, never through a chord.
    let withoutHome = bindings(["A", "B", "Start", "ZR", "Direction Pad"], n64: true)
      .compactMapValues { SynthesizedInput(rawValue: $0) }
    XCTAssertEqual(PhysicalProfileController.pauseTrigger(for: withoutHome, isSnesPad: false), .standard)
  }

  func testChordNeedsBothStartAndSelect() {
    var startOnly = snesBindings()
    startOnly["Button Options"] = nil
    XCTAssertEqual(PhysicalProfileController.pauseTrigger(for: startOnly, isSnesPad: true), .start,
                   "no Select: Start is the fallback, never a chord")
    XCTAssertEqual(PhysicalProfileController.pauseTrigger(for: snesBindings(), isSnesPad: false), .standard,
                   "the chord is for the SNES family; another pad keeps Options alone")
  }

  /// A pad with no Home, no Options and no chord still pauses, from Start.
  func testPadWithNothingElsePausesFromStart() {
    let bare = bindings(["A", "B", "Start", "Direction Pad"], n64: true).compactMapValues { SynthesizedInput(rawValue: $0) }
    XCTAssertEqual(PhysicalProfileController.pauseTrigger(for: bare, isSnesPad: false), .start)
    let noStart = bindings(["A", "B", "Direction Pad"], n64: true).compactMapValues { SynthesizedInput(rawValue: $0) }
    XCTAssertEqual(PhysicalProfileController.pauseTrigger(for: noStart, isSnesPad: false), .standard)
  }

  // MARK: Select + Start chord

  func testChordFiresOnceWhenBothAreHeldInEitherOrder() {
    var chord = SelectStartChord()
    XCTAssertFalse(chord.update(.options, pressed: true), "Select alone")
    XCTAssertTrue(chord.update(.menu, pressed: true), "then Start")
    XCTAssertFalse(chord.update(.menu, pressed: true), "a repeated value while held")
    XCTAssertFalse(chord.update(.options, pressed: true))

    var reversed = SelectStartChord()
    XCTAssertFalse(reversed.update(.menu, pressed: true), "Start alone")
    XCTAssertTrue(reversed.update(.options, pressed: true), "then Select")
  }

  func testChordNeverFiresOnOneButton() {
    var chord = SelectStartChord()
    for _ in 0 ..< 3 {
      XCTAssertFalse(chord.update(.menu, pressed: true))
      XCTAssertFalse(chord.update(.menu, pressed: false))
      XCTAssertFalse(chord.update(.options, pressed: true))
      XCTAssertFalse(chord.update(.options, pressed: false))
    }
  }

  func testChordRearmsOnlyAfterBothAreReleased() {
    var chord = SelectStartChord()
    _ = chord.update(.options, pressed: true)
    XCTAssertTrue(chord.update(.menu, pressed: true))
    XCTAssertFalse(chord.update(.menu, pressed: false))
    XCTAssertFalse(chord.update(.menu, pressed: true), "Select never let go")
    XCTAssertFalse(chord.update(.menu, pressed: false))
    XCTAssertFalse(chord.update(.options, pressed: false))
    XCTAssertFalse(chord.selectHeld)
    XCTAssertFalse(chord.startHeld)
    _ = chord.update(.menu, pressed: true)
    XCTAssertTrue(chord.update(.options, pressed: true), "a new chord after a full release")
  }

  func testChordIgnoresOtherInputs() {
    var chord = SelectStartChord()
    XCTAssertFalse(chord.update(.buttonA, pressed: true))
    XCTAssertFalse(chord.update(.home, pressed: true))
    XCTAssertFalse(chord.update(.menu, pressed: true))
    XCTAssertTrue(chord.update(.options, pressed: true))
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
