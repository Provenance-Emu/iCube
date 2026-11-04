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
  /// NES and SNES Select.
  static let select = "select"
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
  /// N64 C buttons, as Delta skins spell them (`cUp`), Provenance's hyphenated and arrow forms too.
  static let cUp = "cUp", cDown = "cDown", cLeft = "cLeft", cRight = "cRight"
  static let cUpHyphen = "c-up", cDownHyphen = "c-down", cLeftHyphen = "c-left", cRightHyphen = "c-right"
  static let cUpArrow = "c▲", cDownArrow = "c▼", cLeftArrow = "c◀", cRightArrow = "c▶"
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
    SkinInputName.r2: .axisButton(id: ID.gcTriggerR),
    SkinInputName.cUp: .axisButton(id: ID.gcCStick + 1),
    SkinInputName.cDown: .axisButton(id: ID.gcCStick + 2),
    SkinInputName.cLeft: .axisButton(id: ID.gcCStick + 3),
    SkinInputName.cRight: .axisButton(id: ID.gcCStick + 4),
    SkinInputName.cUpHyphen: .axisButton(id: ID.gcCStick + 1),
    SkinInputName.cDownHyphen: .axisButton(id: ID.gcCStick + 2),
    SkinInputName.cLeftHyphen: .axisButton(id: ID.gcCStick + 3),
    SkinInputName.cRightHyphen: .axisButton(id: ID.gcCStick + 4),
    SkinInputName.cUpArrow: .axisButton(id: ID.gcCStick + 1),
    SkinInputName.cDownArrow: .axisButton(id: ID.gcCStick + 2),
    SkinInputName.cLeftArrow: .axisButton(id: ID.gcCStick + 3),
    SkinInputName.cRightArrow: .axisButton(id: ID.gcCStick + 4)
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

  /// NES on each pad a VC NES title accepts, by button name the way the Virtual Console maps it: the VC
  /// emulator reads A as A, so a skin's A presses A. The d-pad is the pad's own (see `dpad(padKind:)`).
  private static let nesGameCubeControls: [String: TouchOverlayControlKind] = [
    SkinInputName.a: .button(id: ID.gcA),
    SkinInputName.b: .button(id: ID.gcB),
    SkinInputName.start: .button(id: ID.gcStart),
    SkinInputName.select: .button(id: ID.gcZ)
  ]

  private static let nesClassicControls: [String: TouchOverlayControlKind] = [
    SkinInputName.a: .button(id: ID.classicA),
    SkinInputName.b: .button(id: ID.classicB),
    SkinInputName.start: .button(id: ID.classicPlus),
    SkinInputName.select: .button(id: ID.classicMinus)
  ]

  /// The sideways remote is held like a NES pad: 2 is A and 1 is B.
  private static let nesSidewaysControls: [String: TouchOverlayControlKind] = [
    SkinInputName.a: .button(id: ID.wiiTwo),
    SkinInputName.b: .button(id: ID.wiiOne),
    SkinInputName.start: .button(id: ID.wiiPlus),
    SkinInputName.select: .button(id: ID.wiiMinus)
  ]

  /// SNES adds X, Y, L and R by name. Y lands on the GameCube's top Y, not its left B; on a touch skin the
  /// art is where its creator drew it, so the thumb still finds the right picture.
  private static let snesGameCubeControls: [String: TouchOverlayControlKind] = nesGameCubeControls.merging([
    SkinInputName.x: .button(id: ID.gcX),
    SkinInputName.y: .button(id: ID.gcY),
    SkinInputName.l: .axisButton(id: ID.gcTriggerL),
    SkinInputName.r: .axisButton(id: ID.gcTriggerR)
  ]) { _, new in new }

  private static let snesClassicControls: [String: TouchOverlayControlKind] = nesClassicControls.merging([
    SkinInputName.x: .button(id: ID.classicX),
    SkinInputName.y: .button(id: ID.classicY),
    SkinInputName.l: .axisButton(id: ID.classicTriggerL),
    SkinInputName.r: .axisButton(id: ID.classicTriggerR)
  ]) { _, new in new }

  private static let specialActions: [String: SkinAction] = [
    SkinInputName.menu: .menu,
    SkinInputName.quickSave: .quickSave,
    SkinInputName.quickLoad: .quickLoad
  ]

  private static func lowercased(_ controls: [String: TouchOverlayControlKind]) -> [String: SkinAction] {
    var table = Dictionary(uniqueKeysWithValues: controls.map { ($0.key.lowercased(), SkinAction.control($0.value)) })
    for (name, action) in specialActions { table[name.lowercased()] = action }
    return table
  }

  private struct GameTypePad: Hashable {
    let gameType: SkinGameType
    let padKind: TouchOverlayPadKind
  }

  /// Virtual Console skins, looked up before (and instead of) the pad tables: a NES skin's `x` means
  /// nothing, rather than the pad's X.
  private static let virtualConsoleTables: [GameTypePad: [String: SkinAction]] = [
    GameTypePad(gameType: .nes, padKind: .gameCube): lowercased(nesGameCubeControls),
    GameTypePad(gameType: .nes, padKind: .wiiClassic): lowercased(nesClassicControls),
    GameTypePad(gameType: .nes, padKind: .wiiRemoteSideways): lowercased(nesSidewaysControls),
    GameTypePad(gameType: .snes, padKind: .gameCube): lowercased(snesGameCubeControls),
    GameTypePad(gameType: .snes, padKind: .wiiClassic): lowercased(snesClassicControls)
  ]

  /// Lookup tables are written with the canonical spellings; matching is case-insensitive.
  private static let tables: [TouchOverlayPadKind: [String: SkinAction]] = {
    [
      .gameCube: lowercased(gameCubeControls),
      .wiiRemote: lowercased(wiiRemoteControls),
      .wiiRemoteSideways: lowercased(wiiRemoteControls),
      .wiiClassic: lowercased(wiiClassicControls)
    ]
  }()

  /// The action of the first input in `inputs` the pad knows; unknown names are skipped. A NES or SNES
  /// `gameType` uses that system's table for the pad, and a pad the system cannot use maps nothing.
  static func action(for inputs: [String], padKind: TouchOverlayPadKind, gameType: SkinGameType? = nil) -> SkinAction? {
    let table: [String: SkinAction]?
    switch gameType {
    case .nes?:
      table = virtualConsoleTables[GameTypePad(gameType: .nes, padKind: padKind)]
    case .snes?:
      table = virtualConsoleTables[GameTypePad(gameType: .snes, padKind: padKind)]
    case .gameCube?, .wii?, nil:
      table = tables[padKind]
    }
    guard let table else { return nil }
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

  /// The pad's own d-pad. NES and SNES skins use it too, on every pad they can replace.
  static func dpad(padKind: TouchOverlayPadKind) -> TouchOverlayControlKind {
    switch padKind {
    case .gameCube: return .dpad(baseId: ID.gcDpadUp)
    case .wiiRemote, .wiiRemoteSideways: return .dpad(baseId: ID.wiiDpadUp)
    case .wiiClassic: return .dpad(baseId: ID.classicDpadUp)
    }
  }
}
#endif
