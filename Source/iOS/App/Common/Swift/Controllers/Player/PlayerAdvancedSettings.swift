// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One numeric setting of a control group (dead zone, gate size, IR or IMU value), as plain values
/// read through `DOLControllerSettingsBridge`.
struct NumericSettingState: Equatable {
  let owner: RemapGroupOwner
  let groupId: Int
  /// Position in the group's settings: what the bridge's setter takes.
  let index: Int
  let name: String
  /// "%", "°", "cm" or "".
  let suffix: String
  let isToggle: Bool
  let isInteger: Bool
  let value: Double
  let minimum: Double
  let maximum: Double
  let defaultValue: Double
  /// Driven by an expression rather than a number: shown, not edited.
  let isExpression: Bool

  var id: String { "setting-\(owner)-\(groupId)-\(index)" }
}

/// The values a numeric setting's picker offers. A slider cannot be reached by a pad on iOS or
/// focused on tvOS (the reason Phase 2 made Opacity a stepped picker), so every number is a picker
/// of about `targetStepCount` steps, which d-pad left/right walks through.
enum NumericSettingSteps {
  /// Step sizes, smallest first. A range is cut into steps of the first size that gives at most
  /// about `targetStepCount` of them.
  private static let stepSizes: [Double] = [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 20, 25, 50, 100]
  static let targetStepCount = 20.0
  private static let tolerance = 1e-6

  static func stepSize(minimum: Double, maximum: Double, isInteger: Bool) -> Double {
    let wanted = max(maximum - minimum, 0) / targetStepCount
    let size = stepSizes.first { $0 >= wanted } ?? stepSizes[stepSizes.count - 1]
    return isInteger ? max(1, size.rounded(.up)) : size
  }

  /// Every multiple of the step inside the range, plus the range's ends, the default and the current
  /// value: the picker always shows a selection and always offers the default back.
  static func values(for setting: NumericSettingState) -> [Double] {
    let size = stepSize(minimum: setting.minimum, maximum: setting.maximum, isInteger: setting.isInteger)
    var candidates = [setting.minimum, setting.maximum, setting.defaultValue, setting.value]
    let first = Int((setting.minimum / size).rounded(.up))
    let last = Int((setting.maximum / size).rounded(.down))
    if first <= last {
      candidates += (first ... last).map { Double($0) * size }
    }
    var values: [Double] = []
    for value in candidates.sorted() {
      if let previous = values.last, value - previous <= tolerance { continue }
      values.append(value)
    }
    return values
  }

  /// The offered value closest to `value`: what the picker shows as selected.
  static func nearest(to value: Double, in values: [Double]) -> Double {
    values.min { abs($0 - value) < abs($1 - value) } ?? value
  }

  /// "25%", "45°", "10 cm", "0.5".
  static func label(_ value: Double, suffix: String) -> String {
    var number = String(format: "%.2f", value)
    while number.hasSuffix("0") { number.removeLast() }
    if number.hasSuffix(".") { number.removeLast() }
    if number == "-0" { number = "0" }
    if suffix.isEmpty { return number }
    return suffix == "%" || suffix == "°" ? number + suffix : number + " " + suffix
  }
}

/// The control groups whose numeric settings Advanced lists (spec: "dead zones, stick ranges, IR/IMU
/// values"): every stick and trigger group, the Wii Remote's pointer (IR) and its motion pointer
/// (IMU). Group ids are the raw core enums, as in `RemapGroup`.
enum AdvancedSettingGroups {
  struct Entry: Equatable {
    let owner: RemapGroupOwner
    let groupId: Int
    let title: String
  }

  /// `WiimoteEmu::WiimoteGroup::IMUPoint` (WiimoteEmu.h:48-64). Its `Enabled` setting is the pad
  /// port's "Aim with Controller Motion"; the Physical Controller profile turns it on.
  static let imuPointGroup = 12

  static func entries(for system: RemapSystem, attachment: Int) -> [Entry] {
    switch system {
    case .gamecube:
      return [
        Entry(owner: .gcPad, groupId: 1, title: L("Control Stick")),
        Entry(owner: .gcPad, groupId: 2, title: L("C-Stick")),
        Entry(owner: .gcPad, groupId: 4, title: L("Triggers")),
      ]
    case .wii:
      var entries = [
        Entry(owner: .wiimote, groupId: 3, title: L("Pointer")),
        Entry(owner: .wiimote, groupId: imuPointGroup, title: L("Motion Pointer")),
      ]
      switch attachment {
      case 1:
        entries.append(Entry(owner: .nunchuk, groupId: 1, title: L("Nunchuk Stick")))
      case 2:
        entries += [
          Entry(owner: .classic, groupId: 3, title: L("Classic Left Stick")),
          Entry(owner: .classic, groupId: 4, title: L("Classic Right Stick")),
          Entry(owner: .classic, groupId: 1, title: L("Classic Triggers")),
        ]
      default:
        break
      }
      return entries
    }
  }
}
