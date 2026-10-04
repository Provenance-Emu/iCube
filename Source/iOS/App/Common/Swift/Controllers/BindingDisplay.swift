// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Which printed labels a pad uses, from its Dolphin device qualifier (`MFi/0/<vendorName>`).
enum DeviceFamily: Equatable {
  case xbox, playStation, nintendo, genericMFi, touchscreen, unknown

  static func from(qualifier: String) -> DeviceFamily {
    if qualifier.isEmpty { return .unknown }
    if qualifier.hasPrefix("iOS/") { return .touchscreen }
    let name = qualifier.split(separator: "/", maxSplits: 2).last.map(String.init)?.lowercased() ?? ""
    if name.contains("xbox") { return .xbox }
    if name.contains("dualsense") || name.contains("dualshock") || name.contains("playstation") { return .playStation }
    if name.contains("pro controller") || name.contains("joy-con") || name.contains("nintendo") { return .nintendo }
    return .genericMFi
  }
}

/// Turns a bound control expression into what a player recognises: `` `Button A` `` on an Xbox pad
/// reads "A", on a DualSense "✕", and the touchscreen's `` `Axis 112` `` "Pointer Up". Only a single
/// backquoted input is reduced; anything else (an OR of two inputs, a hand-written expression) is
/// shown raw, and the raw text stays editable under Advanced.
enum BindingDisplay {
  static func text(for expression: String, family: DeviceFamily) -> String {
    let trimmed = expression.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return RemapExpression.unboundDisplay }
    guard let input = singleInput(trimmed) else { return trimmed }
    if family == .touchscreen { return touchscreenName(input) ?? String(format: L("On-screen %@"), input) }
    return label(for: input, family: family) ?? input
  }

  // MARK: Touchscreen

  /// The iOS touchscreen device numbers its inputs by `ciface::iOS::ButtonType`
  /// (Source/Core/InputCommon/ControllerInterface/iOS/ButtonType.h): `Button 100` is the Wii
  /// Remote's A, `Axis 112` the pointer's up. An on-screen control reads "On-screen A"; what the app
  /// drives from the device's motion or touch (pointer, swing, tilt, shake, accelerometer, gyro)
  /// reads by what it moves. nil for an id with no name here (the guitar, drums and turntable),
  /// which then keeps its number.
  static func touchscreenName(_ input: String) -> String? {
    let parts = input.split(separator: " ")
    guard parts.count == 2, ["Button", "Axis", "Rumble"].contains(parts[0]), let id = Int(parts[1]) else { return nil }
    if let control = onScreenControl(id) { return String(format: L("On-screen %@"), control) }
    return motionInput(id)
  }

  /// Up, down, left, right: the order of every four-way block in ButtonType.h.
  private static let arrows = ["↑", "↓", "←", "→"]

  /// Buttons, sticks and triggers the overlay draws.
  private static func onScreenControl(_ id: Int) -> String? {
    switch id {
    // GameCube (BUTTON_A = 0 … TRIGGER_R = 21).
    case 0: return "A"
    case 1: return "B"
    case 2: return L("Start")
    case 3: return "X"
    case 4: return "Y"
    case 5: return "Z"
    case 6 ... 9: return String(format: L("D-Pad %@"), arrows[id - 6])
    case 11 ... 14: return String(format: L("Control Stick %@"), arrows[id - 11])
    case 16 ... 19: return String(format: L("C-Stick %@"), arrows[id - 16])
    case 20: return "L"
    case 21: return "R"
    // Wii Remote (WIIMOTE_BUTTON_A = 100 … WIIMOTE_RIGHT = 110).
    case 100: return "A"
    case 101: return "B"
    case 102: return "−"
    case 103: return "+"
    case 104: return L("Home")
    case 105: return "1"
    case 106: return "2"
    case 107 ... 110: return String(format: L("D-Pad %@"), arrows[id - 107])
    // Nunchuk (NUNCHUK_BUTTON_C = 200 … NUNCHUK_STICK_RIGHT = 206).
    case 200: return String(format: L("Nunchuk %@"), "C")
    case 201: return String(format: L("Nunchuk %@"), "Z")
    case 203 ... 206: return String(format: L("Nunchuk Stick %@"), arrows[id - 203])
    // Classic Controller (CLASSIC_BUTTON_A = 300 … CLASSIC_TRIGGER_R = 324).
    case 300 ... 303: return String(format: L("Classic %@"), ["A", "B", "X", "Y"][id - 300])
    case 304: return String(format: L("Classic %@"), "−")
    case 305: return String(format: L("Classic %@"), "+")
    case 306: return String(format: L("Classic %@"), L("Home"))
    case 307: return String(format: L("Classic %@"), "ZL")
    case 308: return String(format: L("Classic %@"), "ZR")
    case 309 ... 312: return String(format: L("Classic D-Pad %@"), arrows[id - 309])
    case 314 ... 317: return String(format: L("Classic Left Stick %@"), arrows[id - 314])
    case 319 ... 322: return String(format: L("Classic Right Stick %@"), arrows[id - 319])
    case 323: return String(format: L("Classic %@"), "L")
    case 324: return String(format: L("Classic %@"), "R")
    default: return nil
    }
  }

  /// What the app feeds from the device's touch or motion, and the device's own rumble.
  private static func motionInput(_ id: Int) -> String? {
    let sixWay = [L("Up"), L("Down"), L("Left"), L("Right"), L("Forward"), L("Backward")]
    let tilt = [L("Forward"), L("Backward"), L("Left"), L("Right")]
    let accelerometer = [L("Left"), L("Right"), L("Forward"), L("Backward"), L("Up"), L("Down")]
    let gyroscope = [L("Pitch Up"), L("Pitch Down"), L("Roll Left"), L("Roll Right"), L("Yaw Left"), L("Yaw Right")]
    let axes = ["X", "Y", "Z"]
    switch id {
    case 112 ... 117: return String(format: L("Pointer %@"), sixWay[id - 112])
    case 118: return String(format: L("Pointer %@"), L("Hide"))
    case 120 ... 125: return String(format: L("Swing %@"), sixWay[id - 120])
    case 127 ... 130: return String(format: L("Tilt %@"), tilt[id - 127])
    case 131: return String(format: L("Tilt %@"), L("Modifier"))
    case 132 ... 134: return String(format: L("Shake %@"), axes[id - 132])
    case 208 ... 213: return String(format: L("Nunchuk Swing %@"), sixWay[id - 208])
    case 215 ... 218: return String(format: L("Nunchuk Tilt %@"), tilt[id - 215])
    case 219: return String(format: L("Nunchuk Tilt %@"), L("Modifier"))
    case 220 ... 222: return String(format: L("Nunchuk Shake %@"), axes[id - 220])
    case 625 ... 630: return String(format: L("Accelerometer %@"), accelerometer[id - 625])
    case 631 ... 636: return String(format: L("Gyroscope %@"), gyroscope[id - 631])
    case 700: return L("Rumble")
    case 900 ... 905: return String(format: L("Nunchuk Accelerometer %@"), accelerometer[id - 900])
    default: return nil
    }
  }

  /// The input name when `expression` is exactly one backquoted input, e.g. "`Button A`".
  private static func singleInput(_ expression: String) -> String? {
    guard expression.count > 2, expression.first == "`", expression.last == "`" else { return nil }
    let inner = expression.dropFirst().dropLast()
    return inner.contains("`") ? nil : String(inner)
  }

  private static func label(for input: String, family: DeviceFamily) -> String? {
    if let face = faceButton(input, family: family) { return face }
    if let stick = stickDirection(input) { return stick }
    switch input {
    case "D-Pad Up": return L("D-Pad ↑")
    case "D-Pad Down": return L("D-Pad ↓")
    case "D-Pad Left": return L("D-Pad ←")
    case "D-Pad Right": return L("D-Pad →")
    case "L Shoulder": return family == .xbox ? "LB" : (family == .nintendo ? "L" : "L1")
    case "R Shoulder": return family == .xbox ? "RB" : (family == .nintendo ? "R" : "R1")
    case "L Trigger": return family == .xbox ? "LT" : (family == .nintendo ? "ZL" : "L2")
    case "R Trigger": return family == .xbox ? "RT" : (family == .nintendo ? "ZR" : "R2")
    case "L Stick": return L("Left Stick Click")
    case "R Stick": return L("Right Stick Click")
    case "Menu": return family == .playStation ? L("Options") : (family == .nintendo ? "+" : L("≡ Menu"))
    case "Options": return family == .playStation ? L("Share") : (family == .nintendo ? "−" : L("View"))
    case "Home": return L("Home")
    default: return nil
    }
  }

  /// GameController names face buttons by position (A = bottom, B = right, X = left, Y = top).
  private static func faceButton(_ input: String, family: DeviceFamily) -> String? {
    let position: Int
    switch input {
    case "Button A": position = 0
    case "Button B": position = 1
    case "Button X": position = 2
    case "Button Y": position = 3
    default: return nil
    }
    switch family {
    case .playStation: return ["✕", "○", "□", "△"][position]
    case .nintendo: return ["B", "A", "Y", "X"][position]
    default: return ["A", "B", "X", "Y"][position]
    }
  }

  private static func stickDirection(_ input: String) -> String? {
    let parts = input.split(separator: " ")
    guard parts.count == 3, parts[1] == "Stick" else { return nil }
    let stick = parts[0] == "L" ? L("Left Stick") : (parts[0] == "R" ? L("Right Stick") : nil)
    let arrow: String?
    switch parts[2] {
    case "Y+": arrow = "↑"
    case "Y-": arrow = "↓"
    case "X-": arrow = "←"
    case "X+": arrow = "→"
    default: arrow = nil
    }
    guard let stick, let arrow else { return nil }
    return "\(stick) \(arrow)"
  }
}
