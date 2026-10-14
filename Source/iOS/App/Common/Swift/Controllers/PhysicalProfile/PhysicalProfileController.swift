// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import GameController

/// Wraps a `GCController` the system exposes without an extended or micro gamepad (the
/// Nintendo Switch Online N64 controller on tvOS 17) and synthesizes an extended gamepad from
/// its physical input profile, so the app's pause routes, menu navigation and hub, which only
/// read `extendedGamepad`, see a real pad.
///
/// The core binds the same pad on its own (`MFiController::AddPhysicalProfileInputs`) against
/// the real controller, which is why `ControllerManager` keeps the wrapper for app-side use
/// and `TVControllerMappingBridge` resolves a wrapper back to its base before looking up the
/// core device. Both read one mapping table (`PhysicalProfileBridge`), GameCube / Wii
/// semantics: A and B are the GameCube A and B, the C cluster is the C-Stick (right stick),
/// Z is the GameCube Z trigger, L / R are the analog triggers, ZR is Options (pause menu),
/// Start is Menu (GameCube Start / Wii +) and Home is Home (pause menu).
final class PhysicalProfileController: GCController, DOLPhysicalBaseController {
  /// The real controller. Its profile elements drive the synthesized gamepad.
  let base: GCController
  @objc var dol_baseController: GCController { base }

  private let synthesized = SynthesizedGamepad()
  /// Element name -> synthesized input, as resolved for this pad.
  private(set) var bindings: [String: SynthesizedInput] = [:]
  private var pausedHandler: ((GCController) -> Void)?
  private var cUp = false, cDown = false, cLeft = false, cRight = false

  /// True when `controller` has no extended or micro profile but its physical profile has a
  /// direction input and a face button to synthesize from.
  static func isNeeded(for controller: GCController) -> Bool {
    guard controller.extendedGamepad == nil, controller.microGamepad == nil,
          !(controller is PhysicalProfileController) else { return false }
    return !resolveBindings(for: controller).isEmpty
  }

  /// The bindings the shared mapping produces for `controller`; empty when unusable.
  static func resolveBindings(for controller: GCController) -> [String: SynthesizedInput] {
    let n64 = PhysicalProfileBridge.isN64Pad(
      withVendorName: controller.vendorName, productCategory: controller.productCategory)
    let names = Array(controller.physicalInputProfile.elements.keys)
    return PhysicalProfileBridge.bindings(forElementNames: names, isN64Pad: n64)
      .compactMapValues { SynthesizedInput(rawValue: $0) }
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
    synthesized.hasOptions = bindings.values.contains(.options)
    synthesized.hasHome = bindings.values.contains(.home)
    NSLog("[INPUT] PhysicalProfileController[%@]: %@", base.vendorName ?? "?",
          bindings.sorted { $0.key < $1.key }.map { "\($0.key) -> \($0.value.rawValue)" }.joined(separator: ", "))

    // The framework's pause callback is how tvOS treats a pad's Start / Menu button when nothing
    // else claims it. Keep it claimed, doing nothing, so Start reaches the game through the
    // physical element and never falls back to the system or the app's pause route.
    base.controllerPausedHandler = { _ in }

    for (name, input) in bindings {
      guard let element = profile.elements[name] else { continue }
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
      } else {
        guard let source = element as? GCControllerButtonInput, let target = synthesized.button(for: input) else { continue }
        source.valueChangedHandler = { [weak self, weak target] _, value, pressed in
          guard let self, let target else { return }
          target.update(value: value, pressed: pressed)
          self.synthesized.notify(target)
          if input == .home, pressed { self.pausedHandler?(self) }
        }
      }
    }
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
  override var vendorName: String? { base.vendorName }
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
