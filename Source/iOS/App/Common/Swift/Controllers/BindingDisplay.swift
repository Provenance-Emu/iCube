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
/// reads "A", on a DualSense "✕". Only a single backquoted input is reduced; anything else (an
/// OR of two inputs, a hand-written expression) is shown raw, and the raw text stays editable
/// under Advanced.
enum BindingDisplay {
  static func text(for expression: String, family: DeviceFamily) -> String {
    let trimmed = expression.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return RemapExpression.unboundDisplay }
    guard let input = singleInput(trimmed) else { return trimmed }
    if family == .touchscreen { return String(format: L("On-screen %@"), input) }
    return label(for: input, family: family) ?? input
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
