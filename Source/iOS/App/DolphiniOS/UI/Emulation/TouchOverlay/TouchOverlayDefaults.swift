// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import CoreGraphics
import Foundation

/// The DEFAULT (un-customised) layout of every pad kind, extracted from the four xibs so an
/// upgrader sees no visual jump ("migration from nothing", §2.3 of the design). Each xib is
/// authored at one design size and pins its controls to the bottom and to a horizontal edge with
/// Auto Layout; the numbers below are the control frames at that design size turned into
/// edge insets, which is what those constraints produce on any screen. Both orientations share
/// the same constraints today, so both orientations share these defaults.
///
/// Source frames (x, y, w, h at the design size), kept here so the derivation is checkable:
/// - TCGameCubePad.xib (768x1024): LeftStick (0,768,128,128), DPad (128,896,128,128),
///   CStick (548,896,128,128), B (620,866,46,30), A (676,866,46,30), Y (676,836,46,30),
///   X (722,851,46,30), L (0,821,46,30), START (86,821,46,30), Z (630,821,46,30), R (722,821,46,30).
/// - TCWiiPad.xib (375x667): DPad (0,401,128,128), LeftStick (0,539,128,128), A (309,597,46,30),
///   B (309,527,46,30), One (248,572,46,30), Two (248,622,46,30), Minus (248,522,46,30),
///   Plus (187,552,46,30), HOME (187,477,46,30), C (187,597,46,30), Z (309,477,46,30).
/// - TCSidewaysWiiPad.xib (768x1024): DPad (0,896,128,128), B (25.5,779,77,77), A (705,878,43,43),
///   One (622,941,43,43), Two (705,941,43,43), Plus (630.5,886.5,26,26), Minus (713.5,827,26,26),
///   HOME (368,992,32,32).
/// - TCClassicWiiPad.xib (375x667): ZL (16,302,77,77), L (16,352,77,77), ZR (282,302,77,77),
///   R (282,352,77,77), DPad (22.5,435,115,115), X (269.5,434,43,43), Y (228,471,43,43),
///   A (311,471,43,43), B (269.5,508,43,43), LeftStick (16,543,128,128), RightStick (227,543,128,128),
///   Minus (137.5,639,26,26), HOME (171.5,636,32,32), Plus (211.5,639,26,26).
enum TouchOverlayDefaults {
  /// Design sizes of the xibs the insets were derived from (used by the tests to prove the
  /// defaults reproduce the xib frames exactly).
  static let gameCubeDesignSize = CGSize(width: 768, height: 1024)
  static let wiiRemoteDesignSize = CGSize(width: 375, height: 667)
  static let wiiRemoteSidewaysDesignSize = CGSize(width: 768, height: 1024)
  static let wiiClassicDesignSize = CGSize(width: 375, height: 667)

  static func designSize(for kind: TouchOverlayPadKind) -> CGSize {
    switch kind {
    case .gameCube: return gameCubeDesignSize
    case .wiiRemote: return wiiRemoteDesignSize
    case .wiiRemoteSideways: return wiiRemoteSidewaysDesignSize
    case .wiiClassic: return wiiClassicDesignSize
    }
  }

  // Raw TCButtonType ids the xibs use (TCButtonType.swift). Named here once.
  private enum ID {
    static let gcA = 0, gcB = 1, gcStart = 2, gcX = 3, gcY = 4, gcZ = 5
    static let gcDpadUp = 6, gcMainStick = 10, gcCStick = 15, gcTriggerL = 20, gcTriggerR = 21
    static let wiiA = 100, wiiB = 101, wiiMinus = 102, wiiPlus = 103, wiiHome = 104, wiiOne = 105, wiiTwo = 106
    static let wiiDpadUp = 107
    static let nunchukC = 200, nunchukZ = 201, nunchukStick = 202
    static let classicA = 300, classicB = 301, classicX = 302, classicY = 303, classicMinus = 304
    static let classicPlus = 305, classicHome = 306, classicZL = 307, classicZR = 308
    static let classicDpadUp = 309, classicLeftStick = 313, classicRightStick = 318
    static let classicTriggerL = 323, classicTriggerR = 324
  }

  private static let smallButton = CGSize(width: 46, height: 30)
  private static let stick = CGSize(width: 128, height: 128)

  /// Phase 3 (task item 1): the Wii IR drag/follow surface's default rect is "the whole overlay
  /// minus a safe margin" on every side, not the phase-2 placeholder's literal full bounds — that
  /// margin strip stays reachable for the long-press-to-edit catcher in `TouchOverlayView`, and
  /// gives the group a real, resizable/movable footprint like every other group (§2.4).
  static let irPadMargin: CGFloat = 24

  private static func button(_ id: String, _ raw: Int, _ x: CGFloat, _ y: CGFloat, size: CGSize = smallButton) -> TouchOverlayControl {
    TouchOverlayControl(id: id, kind: .button(id: raw), frame: CGRect(origin: CGPoint(x: x, y: y), size: size))
  }

  private static func axisButton(_ id: String, _ raw: Int, _ x: CGFloat, _ y: CGFloat, size: CGSize = smallButton) -> TouchOverlayControl {
    TouchOverlayControl(id: id, kind: .axisButton(id: raw), frame: CGRect(origin: CGPoint(x: x, y: y), size: size))
  }

  private static func single(_ group: TouchOverlayGroup, _ anchor: TouchOverlayAnchor, inset: CGPoint,
                             size: CGSize, kind: TouchOverlayControlKind, id: String) -> TouchOverlayGroupLayout {
    TouchOverlayGroupLayout(
      group: group,
      placement: TouchOverlayPlacement(anchor, inset: inset, size: size),
      controls: [TouchOverlayControl(id: id, kind: kind, frame: CGRect(origin: .zero, size: size))])
  }

  /// Default groups for a pad kind. Orientation is accepted for future per-orientation tuning;
  /// today both orientations share the xib constraints and therefore these values.
  static func layout(for kind: TouchOverlayPadKind, orientation: TouchOverlayOrientation) -> [TouchOverlayGroupLayout] {
    _ = orientation
    switch kind {
    case .gameCube: return gameCube
    case .wiiRemote: return wiiRemote
    case .wiiRemoteSideways: return wiiRemoteSideways
    case .wiiClassic: return wiiClassic
    }
  }

  static func layout(for group: TouchOverlayGroup, kind: TouchOverlayPadKind,
                     orientation: TouchOverlayOrientation) -> TouchOverlayGroupLayout? {
    layout(for: kind, orientation: orientation).first { $0.group == group }
  }

  // MARK: GameCube (768x1024)

  private static let gameCube: [TouchOverlayGroupLayout] = [
    // LeftStick (0,768,128,128): centre (64,832) -> 64 from the left, 192 up from the bottom.
    single(.gcMainStick, .bottomLeading, inset: CGPoint(x: 64, y: 192), size: stick,
           kind: .stick(baseId: ID.gcMainStick), id: "gc.mainStick"),
    // DPad (128,896,128,128): centre (192,960).
    single(.gcDpad, .bottomLeading, inset: CGPoint(x: 192, y: 64), size: stick,
           kind: .dpad(baseId: ID.gcDpadUp), id: "gc.dpad"),
    // CStick (548,896,128,128): centre (612,960) -> 156 from the right.
    single(.gcCStick, .bottomTrailing, inset: CGPoint(x: 156, y: 64), size: stick,
           kind: .stick(baseId: ID.gcCStick), id: "gc.cStick"),
    // B (620,866) A (676,866) Y (676,836) X (722,851): union (620,836)-(768,896) = 148x60, centre (694,866).
    TouchOverlayGroupLayout(
      group: .gcFaceButtons,
      placement: TouchOverlayPlacement(.bottomTrailing, inset: CGPoint(x: 74, y: 158), size: CGSize(width: 148, height: 60)),
      controls: [
        button("gc.b", ID.gcB, 0, 30), button("gc.a", ID.gcA, 56, 30),
        button("gc.y", ID.gcY, 56, 0), button("gc.x", ID.gcX, 102, 15),
      ]),
    // L (0,821) + START (86,821): union (0,821)-(132,851) = 132x30, centre (66,836).
    TouchOverlayGroupLayout(
      group: .gcLeftShoulder,
      placement: TouchOverlayPlacement(.bottomLeading, inset: CGPoint(x: 66, y: 188), size: CGSize(width: 132, height: 30)),
      controls: [axisButton("gc.l", ID.gcTriggerL, 0, 0), button("gc.start", ID.gcStart, 86, 0)]),
    // Z (630,821) + R (722,821): union (630,821)-(768,851) = 138x30, centre (699,836).
    TouchOverlayGroupLayout(
      group: .gcRightShoulder,
      placement: TouchOverlayPlacement(.bottomTrailing, inset: CGPoint(x: 69, y: 188), size: CGSize(width: 138, height: 30)),
      controls: [button("gc.z", ID.gcZ, 0, 0), axisButton("gc.r", ID.gcTriggerR, 92, 0)]),
  ]

  // MARK: Wii Remote + Nunchuk, upright (375x667)

  private static let wiiRemote: [TouchOverlayGroupLayout] = [
    // DPad (0,401,128,128): centre (64,465) -> 202 up from the bottom.
    single(.wiiDpad, .bottomLeading, inset: CGPoint(x: 64, y: 202), size: stick,
           kind: .dpad(baseId: ID.wiiDpadUp), id: "wii.dpad"),
    // LeftStick (0,539,128,128): centre (64,603).
    single(.nunchukStick, .bottomLeading, inset: CGPoint(x: 64, y: 64), size: stick,
           kind: .stick(baseId: ID.nunchukStick), id: "nunchuk.stick"),
    // B (309,527) above A (309,597): union (309,527)-(355,627) = 46x100, centre (332,577).
    TouchOverlayGroupLayout(
      group: .wiiAB,
      placement: TouchOverlayPlacement(.bottomTrailing, inset: CGPoint(x: 43, y: 90), size: CGSize(width: 46, height: 100)),
      controls: [button("wii.b", ID.wiiB, 0, 0), button("wii.a", ID.wiiA, 0, 70)]),
    // One (248,572) above Two (248,622): union (248,572)-(294,652) = 46x80, centre (271,612).
    TouchOverlayGroupLayout(
      group: .wiiOneTwo,
      placement: TouchOverlayPlacement(.bottomTrailing, inset: CGPoint(x: 104, y: 55), size: CGSize(width: 46, height: 80)),
      controls: [button("wii.one", ID.wiiOne, 0, 0), button("wii.two", ID.wiiTwo, 0, 50)]),
    // HOME (187,477), Minus (248,522), Plus (187,552): union (187,477)-(294,582) = 107x105, centre (240.5,529.5).
    TouchOverlayGroupLayout(
      group: .wiiMinusPlusHome,
      placement: TouchOverlayPlacement(.bottomTrailing, inset: CGPoint(x: 134.5, y: 137.5), size: CGSize(width: 107, height: 105)),
      controls: [button("wii.home", ID.wiiHome, 0, 0), button("wii.minus", ID.wiiMinus, 61, 45), button("wii.plus", ID.wiiPlus, 0, 75)]),
    // C (187,597,46,30): centre (210,612).
    single(.nunchukC, .bottomTrailing, inset: CGPoint(x: 165, y: 55), size: smallButton,
           kind: .button(id: ID.nunchukC), id: "nunchuk.c"),
    // Z (309,477,46,30): centre (332,492).
    single(.nunchukZ, .bottomTrailing, inset: CGPoint(x: 43, y: 175), size: smallButton,
           kind: .button(id: ID.nunchukZ), id: "nunchuk.z"),
    // The drag/follow surface (phase 3): the whole pad inset by `irPadMargin`, movable/resizable
    // like any other group (§2.4) instead of the phase-2 placeholder's literal full bounds.
    TouchOverlayGroupLayout(
      group: .wiiIRPad,
      placement: TouchOverlayPlacement(.fillInset, margin: irPadMargin),
      controls: [TouchOverlayControl(id: "wii.ir", kind: .irSurface, frame: .zero)]),
  ]

  // MARK: Wii Remote sideways (768x1024)

  private static let wiiRemoteSideways: [TouchOverlayGroupLayout] = [
    // DPad (0,896,128,128): centre (64,960).
    single(.wiiDpad, .bottomLeading, inset: CGPoint(x: 64, y: 64), size: stick,
           kind: .dpad(baseId: ID.wiiDpadUp), id: "wii.dpad"),
    // B (25.5,779,77,77): centre (64,817.5).
    single(.sidewaysB, .bottomLeading, inset: CGPoint(x: 64, y: 206.5), size: CGSize(width: 77, height: 77),
           kind: .button(id: ID.wiiB), id: "wii.b"),
    // Minus (713.5,827,26) A (705,878,43) Plus (630.5,886.5,26) One (622,941,43) Two (705,941,43):
    // union (622,827)-(748,984) = 126x157, centre (685,905.5).
    TouchOverlayGroupLayout(
      group: .sidewaysFaceCluster,
      placement: TouchOverlayPlacement(.bottomTrailing, inset: CGPoint(x: 83, y: 118.5), size: CGSize(width: 126, height: 157)),
      controls: [
        button("wii.minus", ID.wiiMinus, 91.5, 0, size: CGSize(width: 26, height: 26)),
        button("wii.a", ID.wiiA, 83, 51, size: CGSize(width: 43, height: 43)),
        button("wii.plus", ID.wiiPlus, 8.5, 59.5, size: CGSize(width: 26, height: 26)),
        button("wii.one", ID.wiiOne, 0, 114, size: CGSize(width: 43, height: 43)),
        button("wii.two", ID.wiiTwo, 83, 114, size: CGSize(width: 43, height: 43)),
      ]),
    // HOME (368,992,32,32): centre (384,1008) = horizontal centre, 16 up.
    single(.sidewaysHome, .bottomCenter, inset: CGPoint(x: 0, y: 16), size: CGSize(width: 32, height: 32),
           kind: .button(id: ID.wiiHome), id: "wii.home"),
  ]

  // MARK: Wii Remote + Classic Controller (375x667)

  private static let wiiClassic: [TouchOverlayGroupLayout] = [
    // ZL (16,302,77,77) above L (16,352,77,77): union (16,302)-(93,429) = 77x127, centre (54.5,365.5).
    TouchOverlayGroupLayout(
      group: .classicLeftShoulder,
      placement: TouchOverlayPlacement(.bottomLeading, inset: CGPoint(x: 54.5, y: 301.5), size: CGSize(width: 77, height: 127)),
      controls: [button("classic.zl", ID.classicZL, 0, 0, size: CGSize(width: 77, height: 77)),
                 axisButton("classic.l", ID.classicTriggerL, 0, 50, size: CGSize(width: 77, height: 77))]),
    // ZR (282,302) above R (282,352): centre (320.5,365.5).
    TouchOverlayGroupLayout(
      group: .classicRightShoulder,
      placement: TouchOverlayPlacement(.bottomTrailing, inset: CGPoint(x: 54.5, y: 301.5), size: CGSize(width: 77, height: 127)),
      controls: [button("classic.zr", ID.classicZR, 0, 0, size: CGSize(width: 77, height: 77)),
                 axisButton("classic.r", ID.classicTriggerR, 0, 50, size: CGSize(width: 77, height: 77))]),
    // DPad (22.5,435,115,115): centre (80,492.5).
    single(.classicDpad, .bottomLeading, inset: CGPoint(x: 80, y: 174.5), size: CGSize(width: 115, height: 115),
           kind: .dpad(baseId: ID.classicDpadUp), id: "classic.dpad"),
    // X (269.5,434) Y (228,471) A (311,471) B (269.5,508), all 43x43: union (228,434)-(354,551) = 126x117, centre (291,492.5).
    TouchOverlayGroupLayout(
      group: .classicFaceButtons,
      placement: TouchOverlayPlacement(.bottomTrailing, inset: CGPoint(x: 84, y: 174.5), size: CGSize(width: 126, height: 117)),
      controls: [
        button("classic.x", ID.classicX, 41.5, 0, size: CGSize(width: 43, height: 43)),
        button("classic.y", ID.classicY, 0, 37, size: CGSize(width: 43, height: 43)),
        button("classic.a", ID.classicA, 83, 37, size: CGSize(width: 43, height: 43)),
        button("classic.b", ID.classicB, 41.5, 74, size: CGSize(width: 43, height: 43)),
      ]),
    // LeftStick (16,543,128,128): centre (80,607). RightStick (227,543,128,128): centre (291,607).
    single(.classicLeftStick, .bottomLeading, inset: CGPoint(x: 80, y: 60), size: stick,
           kind: .stick(baseId: ID.classicLeftStick), id: "classic.leftStick"),
    single(.classicRightStick, .bottomTrailing, inset: CGPoint(x: 84, y: 60), size: stick,
           kind: .stick(baseId: ID.classicRightStick), id: "classic.rightStick"),
    // Minus (137.5,639,26) HOME (171.5,636,32) Plus (211.5,639,26): union (137.5,636)-(237.5,668) = 100x32, centre (187.5,652).
    TouchOverlayGroupLayout(
      group: .classicMinusPlusHome,
      placement: TouchOverlayPlacement(.bottomCenter, inset: CGPoint(x: 0, y: 15), size: CGSize(width: 100, height: 32)),
      controls: [
        button("classic.minus", ID.classicMinus, 0, 3, size: CGSize(width: 26, height: 26)),
        button("classic.home", ID.classicHome, 34, 0, size: CGSize(width: 32, height: 32)),
        button("classic.plus", ID.classicPlus, 74, 3, size: CGSize(width: 26, height: 26)),
      ]),
  ]
}
#endif
