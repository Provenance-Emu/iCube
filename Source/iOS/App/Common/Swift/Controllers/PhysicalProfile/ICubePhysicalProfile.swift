// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import GameController
import GamepadKit

// iCube's side of GamepadKit (github.com/Provenance-Emu/GamepadKit, shared with Provenance and
// iFly). The package wraps a `GCController` the system exposes without an extended gamepad (a
// Switch Online SNES or N64 pad, or a plain USB / Bluetooth HID pad) and synthesizes one from its
// physical input profile, so the app's pause routes, menu navigation and hub, which only read
// `extendedGamepad`, see a real pad.
//
// The core binds the same pad on its own (`MFiController::AddPhysicalProfileInputs`) against the
// real controller, which is why `ControllerManager` keeps the wrapper for app-side use and
// `TVControllerMappingBridge` resolves a wrapper back to its base before looking up the core
// device (`+[DOLPhysicalProfileBridge baseController:]`, which finds the wrapper by its
// Objective-C class name, `GPKPhysicalProfileController`). Wrapper and core read one mapping table, the C++ one, through `PhysicalProfileBridge`
// (GameCube / Wii semantics: A and B are the GameCube A and B, the C cluster is the C-Stick, Z is
// the GameCube Z trigger, L / R are the analog triggers, ZR is Options, Start is Menu).

extension GamepadInput {
  /// The MFi input name the core's table (`PhysicalProfile::Input`) gives this input.
  var coreName: String {
    switch self {
    case .dpad: "D-Pad"
    case .leftThumbstick: "L Stick"
    case .rightThumbstick: "R Stick"
    case .buttonA: "Button A"
    case .buttonB: "Button B"
    case .buttonX: "Button X"
    case .buttonY: "Button Y"
    case .leftShoulder: "L Shoulder"
    case .rightShoulder: "R Shoulder"
    case .leftTrigger: "L Trigger"
    case .rightTrigger: "R Trigger"
    case .menu: "Menu"
    case .options: "Options"
    case .home: "Home"
    case .leftThumbstickButton: "L Stick Button"
    case .rightThumbstickButton: "R Stick Button"
    case .rightStickUp: "R Stick Y+"
    case .rightStickDown: "R Stick Y-"
    case .rightStickLeft: "R Stick X-"
    case .rightStickRight: "R Stick X+"
    }
  }

  private static let byCoreName = Dictionary(uniqueKeysWithValues: allCases.map { ($0.coreName, $0) })

  init?(coreName: String) {
    guard let input = Self.byCoreName[coreName] else { return nil }
    self = input
  }
}

enum ICubePhysicalProfile {
  /// The bindings the core's table produces for `controller` (`PhysicalProfile::ResolveForPad`);
  /// empty when unusable.
  static func bindings(for controller: GCController) -> [String: GamepadInput] {
    inputs(PhysicalProfileBridge.bindings(for: controller))
  }

  /// Bridge output (element name to MFi input name) as package inputs.
  static func inputs(_ coreBindings: [String: String]) -> [String: GamepadInput] {
    coreBindings.compactMapValues { GamepadInput(coreName: $0) }
  }

  /// The reason `PauseGestureTracker` logs for a wrapped pad's own pause trigger. Home is nil:
  /// it pauses through `buttonHome`, like the PlayStation and Xbox Home buttons.
  static func pauseReason(for trigger: PauseTrigger) -> String? {
    switch trigger {
    case .home: nil
    case .chord: "synthesized.selectStartChord"
    case .button: "synthesized.start"
    }
  }
}

extension PhysicalProfileConfiguration {
  /// How iCube wraps a pad:
  /// - Bindings and the pad's name come from the core (`bindingsResolver`, `padName`), so wrapper
  ///   and core cannot disagree. The package's GameCube table decides only the pad's family.
  /// - A pad is wrapped when it has no extended gamepad, its profile has a direction input and a
  ///   face button, and either it has no micro gamepad (the N64 pad on tvOS 17, a plain HID pad)
  ///   or it is a Switch Online pad (the SNES pad, whose micro and legacy profiles lack Start and
  ///   Select). A TV remote never is.
  /// - Pause is Home when the pad has one; Select + Start for the SNES pad; Options alone when
  ///   the pad has it (the N64 pad's ZR), through the app's ordinary Options route; otherwise
  ///   Start, so no pad is left unable to pause. The trigger's buttons still reach the game.
  /// - Options is not reported when it is part of the chord, so Select alone never pauses.
  /// - Every bound button has its system gesture disabled, and a button's pressed handler fires
  ///   before its value handler.
  static let iCube = PhysicalProfileConfiguration(
    mapping: PhysicalProfileMapping(table: .gameCube),
    wrapPolicy: .switchOnlineOrProfileOnly,
    pausePolicy: .homeSnesChordOrStart,
    holdsBackPauseInputs: false,
    optionsExposure: .whenBoundAndNotPauseTrigger,
    homeExposure: .whenBound,
    systemGestureDisabledInputs: Set(GamepadInput.allCases),
    legacyPausedHandler: .homeOnly,
    buttonHandlerOrder: .pressedThenValue,
    playerIndexStorage: .base,
    padName: { PhysicalProfileBridge.coreName(for: $0) },
    isRemote: { $0.isMenuRemote || PhysicalProfileBridge.isRemoteProductCategory($0.productCategory) },
    bindingsResolver: { controller, _ in ICubePhysicalProfile.bindings(for: controller) },
    log: { level, message in
      if level == .info { NSLog("[INPUT] %@", message) }
    }
  )
}

extension PhysicalProfileController {
  /// True when `controller` should be wrapped under iCube's rules.
  static func isNeeded(for controller: GCController) -> Bool {
    isNeeded(for: controller, configuration: .iCube)
  }

  /// Wraps `controller` under iCube's rules.
  convenience init(wrapping controller: GCController) {
    self.init(wrapping: controller, configuration: .iCube)
    // The framework's pause callback is how tvOS treats a pad's Start / Menu button when nothing
    // else claims it. Keep it claimed, doing nothing, so Start reaches the game through the
    // physical element and never falls back to the system or the app's pause route.
    DeprecatedAPIShims.setPausedHandler({ _ in }, on: controller)
    // The SNES pad also has a micro gamepad whose Menu is its Start. Every app route reads the
    // wrapper, which has no micro gamepad; drop a route installed on the real pad before it was
    // wrapped, so Start never reaches the Siri Remote's ungated pause route. A no-op rather than
    // nil: a nil Menu handler hands the button back to the system.
    if let micro = controller.microGamepad {
      micro.buttonMenu.preferredSystemGestureState = .disabled
      micro.buttonMenu.pressedChangedHandler = { _, _, _ in }
    }
  }
}
