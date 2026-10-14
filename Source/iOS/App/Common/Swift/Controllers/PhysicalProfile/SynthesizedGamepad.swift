// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import GameController

/// One input of the extended gamepad a `PhysicalProfileController` synthesizes. Raw values are
/// the MFi input names `PhysicalProfileBridge.bindingsForElementNames` returns, which are the
/// names the core publishes for the same pad, so both layers agree on what every element means.
enum SynthesizedInput: String, CaseIterable {
  case dpad = "D-Pad"
  case leftThumbstick = "L Stick"
  case rightThumbstick = "R Stick"
  case buttonA = "Button A"
  case buttonB = "Button B"
  case buttonX = "Button X"
  case buttonY = "Button Y"
  case leftShoulder = "L Shoulder"
  case rightShoulder = "R Shoulder"
  case leftTrigger = "L Trigger"
  case rightTrigger = "R Trigger"
  case menu = "Menu"
  case options = "Options"
  case home = "Home"
  /// Digital buttons that stand in for a right-stick direction: the N64 C cluster.
  case rightStickUp = "R Stick Y+"
  case rightStickDown = "R Stick Y-"
  case rightStickLeft = "R Stick X-"
  case rightStickRight = "R Stick X+"

  var isCButton: Bool {
    switch self {
    case .rightStickUp, .rightStickDown, .rightStickLeft, .rightStickRight: return true
    default: return false
    }
  }

  var isDirection: Bool {
    switch self {
    case .dpad, .leftThumbstick, .rightThumbstick: return true
    default: return false
    }
  }
}

/// A button whose state is set from code.
final class SynthesizedButtonInput: GCControllerButtonInput {
  private var _value: Float = 0
  private var _isPressed = false
  private var _valueChangedHandler: GCControllerButtonValueChangedHandler?
  private var _pressedChangedHandler: GCControllerButtonValueChangedHandler?

  override var value: Float { _value }
  override var isPressed: Bool { _isPressed }
  override var isAnalog: Bool { false }

  override var valueChangedHandler: GCControllerButtonValueChangedHandler? {
    get { _valueChangedHandler }
    set { _valueChangedHandler = newValue }
  }

  override var pressedChangedHandler: GCControllerButtonValueChangedHandler? {
    get { _pressedChangedHandler }
    set { _pressedChangedHandler = newValue }
  }

  /// Sets the state and fires the handlers a consumer installed (pressed first, on a change).
  func update(value: Float, pressed: Bool) {
    let pressedChanged = pressed != _isPressed
    let valueChanged = value != _value
    _value = value
    _isPressed = pressed
    if pressedChanged { _pressedChangedHandler?(self, value, pressed) }
    if pressedChanged || valueChanged { _valueChangedHandler?(self, value, pressed) }
  }
}

/// An axis whose value is set from code.
final class SynthesizedAxisInput: GCControllerAxisInput {
  private var _value: Float = 0
  private var _valueChangedHandler: GCControllerAxisValueChangedHandler?

  override var value: Float { _value }

  override var valueChangedHandler: GCControllerAxisValueChangedHandler? {
    get { _valueChangedHandler }
    set { _valueChangedHandler = newValue }
  }

  func update(value: Float) {
    guard value != _value else { return }
    _value = value
    _valueChangedHandler?(self, value)
  }
}

/// A direction pad whose axes and direction buttons are set from code.
final class SynthesizedDirectionPad: GCControllerDirectionPad {
  /// A direction button reads pressed past this deflection.
  static let digitalThreshold: Float = 0.5

  private let _xAxis = SynthesizedAxisInput()
  private let _yAxis = SynthesizedAxisInput()
  private let _up = SynthesizedButtonInput()
  private let _down = SynthesizedButtonInput()
  private let _left = SynthesizedButtonInput()
  private let _right = SynthesizedButtonInput()
  private var _valueChangedHandler: GCControllerDirectionPadValueChangedHandler?

  override var xAxis: GCControllerAxisInput { _xAxis }
  override var yAxis: GCControllerAxisInput { _yAxis }
  override var up: GCControllerButtonInput { _up }
  override var down: GCControllerButtonInput { _down }
  override var left: GCControllerButtonInput { _left }
  override var right: GCControllerButtonInput { _right }

  override var valueChangedHandler: GCControllerDirectionPadValueChangedHandler? {
    get { _valueChangedHandler }
    set { _valueChangedHandler = newValue }
  }

  /// Sets the pad from axis values in -1...1 (y up), updating the four direction buttons and
  /// firing the pad handler.
  func update(x: Float, y: Float) {
    _xAxis.update(value: x)
    _yAxis.update(value: y)
    let threshold = Self.digitalThreshold
    _up.update(value: max(0, y), pressed: y > threshold)
    _down.update(value: max(0, -y), pressed: y < -threshold)
    _left.update(value: max(0, -x), pressed: x < -threshold)
    _right.update(value: max(0, x), pressed: x > threshold)
    _valueChangedHandler?(self, x, y)
  }
}

/// Extended gamepad backed by settable elements; `PhysicalProfileController` drives it.
final class SynthesizedGamepad: GCExtendedGamepad {
  let synthesizedDpad = SynthesizedDirectionPad()
  let synthesizedLeftThumbstick = SynthesizedDirectionPad()
  let synthesizedRightThumbstick = SynthesizedDirectionPad()
  let synthesizedButtonA = SynthesizedButtonInput()
  let synthesizedButtonB = SynthesizedButtonInput()
  let synthesizedButtonX = SynthesizedButtonInput()
  let synthesizedButtonY = SynthesizedButtonInput()
  let synthesizedLeftShoulder = SynthesizedButtonInput()
  let synthesizedRightShoulder = SynthesizedButtonInput()
  let synthesizedLeftTrigger = SynthesizedButtonInput()
  let synthesizedRightTrigger = SynthesizedButtonInput()
  let synthesizedMenu = SynthesizedButtonInput()
  let synthesizedOptions = SynthesizedButtonInput()
  let synthesizedHome = SynthesizedButtonInput()

  /// Optional buttons are reported only when the physical pad has them, so the pause routes
  /// and the hub see the truth.
  var hasOptions = false
  var hasHome = false

  weak var owner: GCController?
  private var _valueChangedHandler: GCExtendedGamepadValueChangedHandler?

  override var controller: GCController? { owner }

  override var dpad: GCControllerDirectionPad { synthesizedDpad }
  override var leftThumbstick: GCControllerDirectionPad { synthesizedLeftThumbstick }
  override var rightThumbstick: GCControllerDirectionPad { synthesizedRightThumbstick }
  override var buttonA: GCControllerButtonInput { synthesizedButtonA }
  override var buttonB: GCControllerButtonInput { synthesizedButtonB }
  override var buttonX: GCControllerButtonInput { synthesizedButtonX }
  override var buttonY: GCControllerButtonInput { synthesizedButtonY }
  override var leftShoulder: GCControllerButtonInput { synthesizedLeftShoulder }
  override var rightShoulder: GCControllerButtonInput { synthesizedRightShoulder }
  override var leftTrigger: GCControllerButtonInput { synthesizedLeftTrigger }
  override var rightTrigger: GCControllerButtonInput { synthesizedRightTrigger }
  override var buttonMenu: GCControllerButtonInput { synthesizedMenu }
  override var buttonOptions: GCControllerButtonInput? { hasOptions ? synthesizedOptions : nil }
  override var buttonHome: GCControllerButtonInput? { hasHome ? synthesizedHome : nil }
  override var leftThumbstickButton: GCControllerButtonInput? { nil }
  override var rightThumbstickButton: GCControllerButtonInput? { nil }

  override var valueChangedHandler: GCExtendedGamepadValueChangedHandler? {
    get { _valueChangedHandler }
    set { _valueChangedHandler = newValue }
  }

  /// Element for a synthesized button input, or nil for pads and C buttons.
  func button(for input: SynthesizedInput) -> SynthesizedButtonInput? {
    switch input {
    case .buttonA: return synthesizedButtonA
    case .buttonB: return synthesizedButtonB
    case .buttonX: return synthesizedButtonX
    case .buttonY: return synthesizedButtonY
    case .leftShoulder: return synthesizedLeftShoulder
    case .rightShoulder: return synthesizedRightShoulder
    case .leftTrigger: return synthesizedLeftTrigger
    case .rightTrigger: return synthesizedRightTrigger
    case .menu: return synthesizedMenu
    case .options: return synthesizedOptions
    case .home: return synthesizedHome
    default: return nil
    }
  }

  func pad(for input: SynthesizedInput) -> SynthesizedDirectionPad? {
    switch input {
    case .dpad: return synthesizedDpad
    case .leftThumbstick: return synthesizedLeftThumbstick
    case .rightThumbstick: return synthesizedRightThumbstick
    default: return nil
    }
  }

  /// Tells whole-gamepad observers (library and menu navigation) that `element` changed.
  func notify(_ element: GCControllerElement) {
    _valueChangedHandler?(self, element)
  }
}
