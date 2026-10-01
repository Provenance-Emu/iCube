// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation

/// Input names a Delta/Manic skin uses for its buttons and thumbsticks, declared once. Matching is
/// case-insensitive (see `SkinInputMap`), so only the canonical spelling lives here.
enum SkinInputName {
  static let a = "a"
  static let b = "b"
  static let x = "x"
  static let y = "y"
  static let start = "start"
  static let z = "z"
  static let c = "c"
  static let l = "l"
  static let r = "r"
  static let l1 = "l1"
  static let r1 = "r1"
  static let l2 = "l2"
  static let r2 = "r2"
  static let zl = "zl"
  static let zr = "zr"
  static let one = "one"
  static let two = "two"
  static let digitOne = "1"
  static let digitTwo = "2"
  static let minus = "minus"
  static let plus = "plus"
  static let home = "home"
  static let menu = "menu"
  static let quickSave = "quickSave"
  static let quickLoad = "quickLoad"
  static let leftThumbstick = "leftThumbstick"
  static let rightThumbstick = "rightThumbstick"
}

/// What a skin input does: drive a touch overlay control, or one of the app-level actions.
enum SkinAction: Equatable {
  case control(TouchOverlayControlKind)
  case menu
  case quickSave
  case quickLoad
}

/// Pure mapping from skin input names to the touch overlay's control kinds. The raw
/// `TCButtonType` ids come from `TouchOverlayDefaults.ButtonID`, so they match the xib pads and
/// the Touchscreen.ini profiles.
enum SkinInputMap {
  private typealias ID = TouchOverlayDefaults.ButtonID

  private static let gameCubeControls: [String: TouchOverlayControlKind] = [
    SkinInputName.a: .button(id: ID.gcA),
    SkinInputName.b: .button(id: ID.gcB),
    SkinInputName.x: .button(id: ID.gcX),
    SkinInputName.y: .button(id: ID.gcY),
    SkinInputName.start: .button(id: ID.gcStart),
    SkinInputName.z: .button(id: ID.gcZ),
    SkinInputName.r1: .button(id: ID.gcZ),
    SkinInputName.l: .axisButton(id: ID.gcTriggerL),
    SkinInputName.l2: .axisButton(id: ID.gcTriggerL),
    SkinInputName.r: .axisButton(id: ID.gcTriggerR),
    SkinInputName.r2: .axisButton(id: ID.gcTriggerR)
  ]

  /// Wii Remote buttons plus the Nunchuk's C and Z, shared by the upright and sideways remotes.
  private static let wiiRemoteControls: [String: TouchOverlayControlKind] = [
    SkinInputName.a: .button(id: ID.wiiA),
    SkinInputName.b: .button(id: ID.wiiB),
    SkinInputName.one: .button(id: ID.wiiOne),
    SkinInputName.digitOne: .button(id: ID.wiiOne),
    SkinInputName.two: .button(id: ID.wiiTwo),
    SkinInputName.digitTwo: .button(id: ID.wiiTwo),
    SkinInputName.minus: .button(id: ID.wiiMinus),
    SkinInputName.plus: .button(id: ID.wiiPlus),
    SkinInputName.home: .button(id: ID.wiiHome),
    SkinInputName.c: .button(id: ID.nunchukC),
    SkinInputName.z: .button(id: ID.nunchukZ)
  ]

  /// The Classic Controller has no `1`/`2` and no Nunchuk, so those names are deliberately absent.
  private static let wiiClassicControls: [String: TouchOverlayControlKind] = [
    SkinInputName.a: .button(id: ID.classicA),
    SkinInputName.b: .button(id: ID.classicB),
    SkinInputName.x: .button(id: ID.classicX),
    SkinInputName.y: .button(id: ID.classicY),
    SkinInputName.minus: .button(id: ID.classicMinus),
    SkinInputName.plus: .button(id: ID.classicPlus),
    SkinInputName.home: .button(id: ID.classicHome),
    SkinInputName.zl: .button(id: ID.classicZL),
    SkinInputName.zr: .button(id: ID.classicZR),
    SkinInputName.l: .axisButton(id: ID.classicTriggerL),
    SkinInputName.l2: .axisButton(id: ID.classicTriggerL),
    SkinInputName.r: .axisButton(id: ID.classicTriggerR),
    SkinInputName.r2: .axisButton(id: ID.classicTriggerR)
  ]

  private static let specialActions: [String: SkinAction] = [
    SkinInputName.menu: .menu,
    SkinInputName.quickSave: .quickSave,
    SkinInputName.quickLoad: .quickLoad
  ]

  /// Lookup tables are written with the canonical spellings; matching is case-insensitive.
  private static let tables: [TouchOverlayPadKind: [String: SkinAction]] = {
    func lowercased(_ controls: [String: TouchOverlayControlKind]) -> [String: SkinAction] {
      var table = Dictionary(uniqueKeysWithValues: controls.map { ($0.key.lowercased(), SkinAction.control($0.value)) })
      for (name, action) in specialActions { table[name.lowercased()] = action }
      return table
    }
    return [
      .gameCube: lowercased(gameCubeControls),
      .wiiRemote: lowercased(wiiRemoteControls),
      .wiiRemoteSideways: lowercased(wiiRemoteControls),
      .wiiClassic: lowercased(wiiClassicControls)
    ]
  }()

  /// The action of the first input in `inputs` the pad knows; unknown names are skipped.
  static func action(for inputs: [String], padKind: TouchOverlayPadKind) -> SkinAction? {
    guard let table = tables[padKind] else { return nil }
    for input in inputs {
      if let action = table[input.lowercased()] { return action }
    }
    return nil
  }

  /// The stick a skin thumbstick dict (`leftThumbstick` / `rightThumbstick`) drives. The upright
  /// and sideways remotes only have the Nunchuk stick, which a skin calls the left thumbstick.
  static func stick(prefix: String, padKind: TouchOverlayPadKind) -> TouchOverlayControlKind? {
    let isLeft = prefix.lowercased() == SkinInputName.leftThumbstick.lowercased()
    let isRight = prefix.lowercased() == SkinInputName.rightThumbstick.lowercased()
    switch padKind {
    case .gameCube:
      if isLeft { return .stick(baseId: ID.gcMainStick) }
      return isRight ? .stick(baseId: ID.gcCStick) : nil
    case .wiiRemote, .wiiRemoteSideways:
      return isLeft ? .stick(baseId: ID.nunchukStick) : nil
    case .wiiClassic:
      if isLeft { return .stick(baseId: ID.classicLeftStick) }
      return isRight ? .stick(baseId: ID.classicRightStick) : nil
    }
  }

  static func dpad(padKind: TouchOverlayPadKind) -> TouchOverlayControlKind {
    switch padKind {
    case .gameCube: return .dpad(baseId: ID.gcDpadUp)
    case .wiiRemote, .wiiRemoteSideways: return .dpad(baseId: ID.wiiDpadUp)
    case .wiiClassic: return .dpad(baseId: ID.classicDpadUp)
    }
  }
}
#endif
