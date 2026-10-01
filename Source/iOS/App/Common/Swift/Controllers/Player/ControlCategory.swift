// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The player screen's Buttons sections (controller hub spec, "Player screen" item 4): every
/// capturable control, grouped by what it is on the controller rather than by Dolphin's internal
/// group. Keyed by owner, raw group id and the control's index in its group; the indices follow the
/// core's `AddInput` order (GCPadEmu.cpp:46-50, WiimoteEmu.cpp:214-218, Nunchuk.cpp:37-38,
/// Classic.cpp:56-61).
enum ControlCategory: CaseIterable {
  case face
  case dPad
  case sticks
  case triggers
  case system
  case motion

  var id: String {
    switch self {
    case .face: return "face"
    case .dPad: return "dpad"
    case .sticks: return "sticks"
    case .triggers: return "triggers"
    case .system: return "system"
    case .motion: return "motion"
    }
  }

  var title: String {
    switch self {
    case .face: return L("Face Buttons")
    case .dPad: return L("D-Pad")
    case .sticks: return L("Sticks")
    case .triggers: return L("Triggers")
    case .system: return L("System")
    case .motion: return L("Motion")
    }
  }

  /// nil: not listed under Buttons. Rumble is an output, and capture only listens to inputs; the
  /// Options groups hold settings and no controls. Both stay editable as raw expressions under
  /// Advanced.
  static func of(owner: RemapGroupOwner, groupId: Int, index: Int) -> ControlCategory? {
    switch owner {
    case .gcPad:
      // PadGroup: Buttons=0 (A B X Y Z START), MainStick=1, CStick=2, DPad=3, Triggers=4, Rumble=5.
      switch groupId {
      case 0: return index < 4 ? .face : (index == 4 ? .triggers : .system)
      case 1, 2: return .sticks
      case 3: return .dPad
      case 4: return .triggers
      default: return nil
      }
    case .wiimote:
      // WiimoteGroup: Buttons=0 (A B 1 2 - + HOME), DPad=1, Shake=2, Point=3, Tilt=4, Swing=5, Rumble=6.
      switch groupId {
      case 0: return index < 4 ? .face : .system
      case 1: return .dPad
      case 2, 3, 4, 5: return .motion
      default: return nil
      }
    case .nunchuk:
      // NunchukGroup: Buttons=0 (C Z), Stick=1, Tilt=2, Swing=3, Shake=4.
      switch groupId {
      case 0: return .triggers
      case 1: return .sticks
      case 2, 3, 4: return .motion
      default: return nil
      }
    case .classic:
      // ClassicGroup: Buttons=0 (A B X Y ZL ZR - + HOME), Triggers=1, DPad=2, LeftStick=3, RightStick=4.
      switch groupId {
      case 0: return index < 4 ? .face : (index < 6 ? .triggers : .system)
      case 1: return .triggers
      case 2: return .dPad
      case 3, 4: return .sticks
      default: return nil
      }
    }
  }

  /// A row title that says which group the control belongs to: under Sticks, a bare "Up" could be
  /// either stick. The Wii Remote's and the GameCube pad's own buttons keep their printed name; an
  /// extension's say which extension, because a Wii Remote + Classic has two "A" buttons.
  static func title(for row: RemapControlRow) -> String {
    guard let format = titleFormat(owner: row.owner, groupId: row.groupId) else { return row.name }
    return String(format: format, row.name)
  }

  private static func titleFormat(owner: RemapGroupOwner, groupId: Int) -> String? {
    switch (owner, groupId) {
    case (.gcPad, 1): return L("Control Stick %@")
    case (.gcPad, 2): return L("C-Stick %@")
    case (.gcPad, 3): return L("D-Pad %@")
    case (.gcPad, 5): return L("Rumble %@")
    case (.wiimote, 1): return L("D-Pad %@")
    case (.wiimote, 2): return L("Shake %@")
    case (.wiimote, 3): return L("Pointer %@")
    case (.wiimote, 4): return L("Tilt %@")
    case (.wiimote, 5): return L("Swing %@")
    case (.wiimote, 6): return L("Rumble %@")
    case (.nunchuk, 0): return L("Nunchuk %@")
    case (.nunchuk, 1): return L("Nunchuk Stick %@")
    case (.nunchuk, 2): return L("Nunchuk Tilt %@")
    case (.nunchuk, 3): return L("Nunchuk Swing %@")
    case (.nunchuk, 4): return L("Nunchuk Shake %@")
    case (.classic, 0), (.classic, 1): return L("Classic %@")
    case (.classic, 2): return L("Classic D-Pad %@")
    case (.classic, 3): return L("Classic Left Stick %@")
    case (.classic, 4): return L("Classic Right Stick %@")
    default: return nil
    }
  }

  /// The Buttons sections: categories in `allCases` order, each with its rows in the order
  /// `controls` lists them (the `RemapGroup` order). Empty categories are left out.
  static func grouped(_ controls: [RemapControlRow]) -> [(category: ControlCategory, rows: [RemapControlRow])] {
    allCases.compactMap { category in
      let rows = controls.filter { of(owner: $0.owner, groupId: $0.groupId, index: $0.index) == category }
      return rows.isEmpty ? nil : (category, rows)
    }
  }
}
