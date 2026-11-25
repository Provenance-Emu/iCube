// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import GameController

/// Wraps a `GCController` the system exposes without an extended or micro gamepad (the
/// Nintendo Switch Online N64 controller on tvOS 17, or a plain USB / Bluetooth HID pad, product
/// category "HID"), or a Switch Online pad it exposes without
/// an extended one (the SNES controller, which gets only the basic MFi profile: no Start or
/// Select), and synthesizes an extended gamepad from its physical input profile, so the app's
/// pause routes, menu navigation and hub, which only read `extendedGamepad`, see a real pad.
///
/// The core binds the same pad on its own (`MFiController::AddPhysicalProfileInputs`) against
/// the real controller, which is why `ControllerManager` keeps the wrapper for app-side use
/// and `TVControllerMappingBridge` resolves a wrapper back to its base before looking up the
/// core device. Both read one mapping table (`PhysicalProfileBridge`), GameCube / Wii
/// semantics: A and B are the GameCube A and B, the C cluster is the C-Stick (right stick),
/// Z is the GameCube Z trigger, L / R are the analog triggers, ZR is Options (pause menu),
/// Start is Menu (GameCube Start / Wii +) and Home is Home (pause menu). The SNES pad has no Home
/// and its Select is the only Options, so it pauses from Select + Start held together
/// (`PauseTrigger.selectStartChord`), and Start and Select alone reach the game.
final class PhysicalProfileController: GCController, DOLPhysicalBaseController {
  /// The real controller. Its profile elements drive the synthesized gamepad.
  let base: GCController
  @objc var dol_baseController: GCController { base }

  private let synthesized = SynthesizedGamepad()
  /// Element name -> synthesized input, as resolved for this pad.
  private(set) var bindings: [String: SynthesizedInput] = [:]
  private(set) var pauseTrigger = PauseTrigger.standard
  private var pausedHandler: ((GCController) -> Void)?
  private var cUp = false, cDown = false, cLeft = false, cRight = false
  private var chord = SelectStartChord()
  /// Per trigger axis (by element name): whether it rests at -1 rather than 0.
  private var axisRestsAtMinusOne: [String: ObjCBool] = [:]

  /// A trigger driven from an axis reads pressed past this value.
  static let triggerAxisPressedThreshold: Float = 0.25

  /// Called with a reason when the pad asks for the pause menu itself: Select + Start completing
  /// the chord (`PauseTrigger.selectStartChord`) or Start on a pad with nothing else
  /// (`PauseTrigger.start`). `installExtraInputHandlers` points it at the app's pause route.
  var pauseRequestHandler: ((String) -> Void)?

  /// How a wrapped pad reaches the pause menu.
  enum PauseTrigger: Equatable {
    /// Its Home button (`synthesized.buttonHome`), as on PlayStation and Xbox pads.
    case home
    /// Select + Start held together: a pad whose only Options is its Select, with no Home.
    /// Options is then not exposed, so Select alone never pauses.
    case selectStartChord
    /// The extended-gamepad routes: Options when the pad has it (N64 ZR).
    case standard
    /// Start, for a pad with no Home, no Options and no chord, so it can always pause. Start
    /// still reaches the game; the pause stops emulation right after.
    case start
  }

  /// True when `controller` should be wrapped (`shouldWrap`).
  static func isNeeded(for controller: GCController) -> Bool {
    guard !(controller is PhysicalProfileController) else { return false }
    return shouldWrap(
      hasExtendedGamepad: controller.extendedGamepad != nil, hasMicroGamepad: controller.microGamepad != nil,
      isMenuRemote: controller.isMenuRemote
        || PhysicalProfileBridge.isRemoteProductCategory(controller.productCategory),
      isSwitchOnlinePad: PhysicalProfileBridge.isSwitchOnlinePad(
        withVendorName: controller.vendorName, productCategory: controller.productCategory),
      bindings: resolveBindings(for: controller))
  }

  /// A pad is wrapped when it has no extended gamepad, its physical profile has a direction input
  /// and a face button, and either it has no micro gamepad either (the N64 pad on tvOS 17) or it
  /// is a Switch Online pad (the SNES pad, whose micro and legacy profiles lack Start / Select).
  /// A TV remote never is: the Siri Remote's profile has a direction pad and Button A too, and a
  /// wrapper would turn it into a player. `isMenuRemote` is also true for any other product
  /// category naming a remote, with or without a micro gamepad.
  static func shouldWrap(hasExtendedGamepad: Bool, hasMicroGamepad: Bool, isMenuRemote: Bool,
                         isSwitchOnlinePad: Bool, bindings: [String: SynthesizedInput]) -> Bool {
    guard !hasExtendedGamepad, !isMenuRemote, !bindings.isEmpty else { return false }
    return !hasMicroGamepad || isSwitchOnlinePad
  }

  /// The bindings the shared mapping produces for `controller`; empty when unusable.
  static func resolveBindings(for controller: GCController) -> [String: SynthesizedInput] {
    PhysicalProfileBridge.bindings(for: controller).compactMapValues { SynthesizedInput(rawValue: $0) }
  }

  /// What the core binds for the same pad (`PhysicalProfile::ResolveForPad`): a Switch Online pad
  /// and a remote by name alone, any other pad also by position (leftover direction elements, then
  /// leftover numbered buttons as A, B, X, Y, L, R, L2, R2, Select, Start, L3, R3), and an axis
  /// named as a trigger when no button took that trigger.
  static func resolveBindings(buttonNames: [String], directionNames: [String], axisNames: [String] = [],
                              vendorName: String?, productCategory: String?) -> [String: SynthesizedInput] {
    PhysicalProfileBridge.bindings(
      forVendorName: vendorName, productCategory: productCategory, buttonNames: buttonNames,
      directionNames: directionNames, axisNames: axisNames
    ).compactMapValues { SynthesizedInput(rawValue: $0) }
  }

  /// By name alone, whatever the pad.
  static func resolveBindings(elementNames: [String], vendorName: String?,
                              productCategory: String?) -> [String: SynthesizedInput] {
    let n64 = PhysicalProfileBridge.isN64Pad(withVendorName: vendorName, productCategory: productCategory)
    return PhysicalProfileBridge.bindings(forElementNames: elementNames, isN64Pad: n64)
      .compactMapValues { SynthesizedInput(rawValue: $0) }
  }

  /// Home when the pad has one; Select + Start for the SNES pad, which has Start and Select but
  /// no Home (and ZL / ZR the system does not expose); Options alone when the pad has it (keyed on
  /// the SNES family, so the N64 pad's ZR keeps pausing on its own); otherwise Start, so no pad is
  /// left unable to pause (Apple's N64 description is unconfirmed and may lack Home).
  static func pauseTrigger(for bindings: [String: SynthesizedInput], isSnesPad: Bool) -> PauseTrigger {
    let inputs = Set(bindings.values)
    if inputs.contains(.home) { return .home }
    if isSnesPad, inputs.contains(.menu), inputs.contains(.options) { return .selectStartChord }
    if !inputs.contains(.options), inputs.contains(.menu) { return .start }
    return .standard
  }

  init(wrapping controller: GCController) {
    base = controller
    super.init()
    synthesized.owner = self
    bind()
  }

  private func bind() {
    let profile = base.physicalInputProfile
    bindings = Self.resolveBindings(for: base)
    pauseTrigger = Self.pauseTrigger(
      for: bindings,
      isSnesPad: PhysicalProfileBridge.isSnesPad(withVendorName: base.vendorName, productCategory: base.productCategory))
    synthesized.hasOptions = bindings.values.contains(.options) && pauseTrigger != .selectStartChord
    synthesized.hasHome = bindings.values.contains(.home)
    synthesized.hasLeftThumbstickButton = bindings.values.contains(.leftThumbstickButton)
    synthesized.hasRightThumbstickButton = bindings.values.contains(.rightThumbstickButton)
    NSLog("[INPUT] PhysicalProfileController[%@]: pause=%@ %@", base.vendorName ?? "?", String(describing: pauseTrigger),
          bindings.sorted { $0.key < $1.key }.map { "\($0.key) -> \($0.value.rawValue)" }.joined(separator: ", "))

    // The framework's pause callback is how tvOS treats a pad's Start / Menu button when nothing
    // else claims it. Keep it claimed, doing nothing, so Start reaches the game through the
    // physical element and never falls back to the system or the app's pause route.
    DeprecatedAPIShims.setPausedHandler({ _ in }, on: base)
    // The SNES pad also has a micro gamepad whose Menu is its Start. Every app route reads the
    // wrapper, which has no micro gamepad; drop a route installed on the real pad before it was
    // wrapped, so Start never reaches the Siri Remote's ungated pause route. A no-op rather than
    // nil: a nil Menu handler hands the button back to the system.
    if let micro = base.microGamepad {
      micro.buttonMenu.preferredSystemGestureState = .disabled
      micro.buttonMenu.pressedChangedHandler = { _, _, _ in }
    }

    // The bridge names each element once; this only guards an element listed under two kinds.
    var bound: Set<ObjectIdentifier> = []
    for (name, input) in bindings.sorted(by: { $0.key < $1.key }) {
      guard let element = profile.elements[name], bound.insert(ObjectIdentifier(element)).inserted else { continue }
      if let button = element as? GCControllerButtonInput {
        button.preferredSystemGestureState = .disabled
      }
      if input.isDirection {
        guard let source = element as? GCControllerDirectionPad, let target = synthesized.pad(for: input) else { continue }
        source.valueChangedHandler = { [weak self, weak target] _, x, y in
          guard let self, let target else { return }
          target.update(x: x, y: y)
          self.synthesized.notify(target)
        }
      } else if input.isCButton {
        guard let source = element as? GCControllerButtonInput else { continue }
        source.valueChangedHandler = { [weak self] _, _, pressed in
          self?.setCButton(input, pressed: pressed)
        }
      } else if let axis = element as? GCControllerAxisInput {
        bindTriggerAxis(axis, to: input, named: name)
      } else {
        guard let source = element as? GCControllerButtonInput, let target = synthesized.button(for: input) else { continue }
        source.valueChangedHandler = { [weak self, weak target] _, value, pressed in
          guard let self, let target else { return }
          let wasPressed = target.isPressed
          target.update(value: value, pressed: pressed)
          self.synthesized.notify(target)
          if input == .home, pressed { self.pausedHandler?(self) }
          if self.pauseTrigger == .selectStartChord, self.chord.update(input, pressed: pressed) {
            NSLog("[INPUT] PhysicalProfileController[%@]: Select + Start -> pause menu", self.base.vendorName ?? "?")
            self.pauseRequestHandler?("synthesized.selectStartChord")
          }
          if self.pauseTrigger == .start, input == .menu, pressed, !wasPressed {
            self.pauseRequestHandler?("synthesized.start")
          }
        }
      }
    }
  }

  /// Drives a synthesized trigger from an axis, for a pad that reports its analog triggers as axes
  /// only. Such an axis rests at 0 on some pads and at -1 on others (`PhysicalProfileBridge
  /// .triggerValue`).
  private func bindTriggerAxis(_ axis: GCControllerAxisInput, to input: SynthesizedInput, named name: String) {
    guard input == .leftTrigger || input == .rightTrigger, let target = synthesized.button(for: input) else { return }
    axisRestsAtMinusOne[name] = false
    let update: (Float) -> Void = { [weak self, weak target] raw in
      guard let self, let target, var rests = self.axisRestsAtMinusOne[name] else { return }
      let value = PhysicalProfileBridge.triggerValue(forAxisValue: raw, restsAtMinusOne: &rests)
      self.axisRestsAtMinusOne[name] = rests
      target.update(value: value, pressed: value > Self.triggerAxisPressedThreshold)
      self.synthesized.notify(target)
    }
    update(axis.value)
    axis.valueChangedHandler = { _, raw in update(raw) }
  }

  /// The N64 C cluster is four digital buttons; present them as the right stick (C-Stick).
  private func setCButton(_ input: SynthesizedInput, pressed: Bool) {
    switch input {
    case .rightStickUp: cUp = pressed
    case .rightStickDown: cDown = pressed
    case .rightStickLeft: cLeft = pressed
    case .rightStickRight: cRight = pressed
    default: return
    }
    let x: Float = (cRight ? 1 : 0) - (cLeft ? 1 : 0)
    let y: Float = (cUp ? 1 : 0) - (cDown ? 1 : 0)
    synthesized.synthesizedRightThumbstick.update(x: x, y: y)
    synthesized.notify(synthesized.synthesizedRightThumbstick)
  }

  // MARK: GCController

  override var extendedGamepad: GCExtendedGamepad? { synthesized }
  override var microGamepad: GCMicroGamepad? { nil }
  override var physicalInputProfile: GCPhysicalInputProfile { base.physicalInputProfile }

  /// Never nil: an unnamed pad gets the name the core gives it (`MFiController::NameFor`).
  override var vendorName: String? { PhysicalProfileBridge.coreName(for: base) }

  override var productCategory: String { base.productCategory }
  override var isAttachedToDevice: Bool { false }
  override var haptics: GCDeviceHaptics? { base.haptics }
  override var light: GCDeviceLight? { base.light }
  override var battery: GCDeviceBattery? { base.battery }
  override var motion: GCMotion? { base.motion }

  /// The synthesized elements are plain values, so the controller is its own snapshot.
  override func capture() -> GCController { self }

  /// Lives on the real controller: `ControllerManager.syncPlayerIndices` writes it there, and
  /// the hub reads it through the wrapper.
  override var playerIndex: GCControllerPlayerIndex {
    get { base.playerIndex }
    set { base.playerIndex = newValue }
  }

  /// Fired by the pad's Home button, never by Start, so Start reaches the game.
  override var controllerPausedHandler: ((GCController) -> Void)? {
    get { pausedHandler }
    set { pausedHandler = newValue }
  }
}

/// Select + Start held together, the pause chord of a pad with no Home (the SNES pad). Fires once
/// when the second of the two goes down, in either order, and again only after both are released.
struct SelectStartChord {
  private(set) var selectHeld = false
  private(set) var startHeld = false
  private var fired = false

  /// Records a transition of `input`; true when it completes the chord. Start is `.menu` and
  /// Select is `.options`; other inputs are ignored.
  mutating func update(_ input: SynthesizedInput, pressed: Bool) -> Bool {
    switch input {
    case .menu: startHeld = pressed
    case .options: selectHeld = pressed
    default: return false
    }
    if !selectHeld, !startHeld { fired = false }
    guard selectHeld, startHeld, !fired else { return false }
    fired = true
    return true
  }
}
