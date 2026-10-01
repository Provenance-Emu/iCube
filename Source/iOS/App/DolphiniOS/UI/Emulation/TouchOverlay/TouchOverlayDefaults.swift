// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import CoreGraphics
import Foundation
import UIKit

/// The DEFAULT (un-customised) layout of every pad kind for a given screen.
///
/// GameCube is computed from the canvas and safe area (`gameCube(canvas:safeArea:orientation:)`):
/// the xib it used to copy was authored for a 768x1024 iPad in portrait with 46x30 buttons, so on
/// phones its groups overlapped and its round buttons came out as 30 pt dots.
///
/// The Wii pads still come from their xibs, shifted inward by the safe area so nothing sits under
/// the notch or the home indicator. Each xib pins its controls to the bottom and to a horizontal
/// edge with Auto Layout; the numbers below are the control frames at that design size turned
/// into edge insets, which is what those constraints produce on any screen.
///
/// Source frames (x, y, w, h at the design size), kept here so the derivation is checkable:
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

  private static func single(_ group: TouchOverlayGroup, _ inset: TouchOverlayPlacement.Inset,
                             size: CGSize, kind: TouchOverlayControlKind, id: String) -> TouchOverlayGroupLayout {
    single(group, inset.anchor, inset: CGPoint(x: inset.x, y: inset.y), size: size, kind: kind, id: id)
  }

  /// Default groups for a pad kind on a `canvas`-sized overlay whose system-owned edges are
  /// `safeArea`. `canvas` is the overlay's full size, safe area included.
  static func layout(for kind: TouchOverlayPadKind, orientation: TouchOverlayOrientation,
                     canvas: CGSize, safeArea: UIEdgeInsets) -> [TouchOverlayGroupLayout] {
    switch kind {
    case .gameCube: return gameCube(canvas: canvas, safeArea: safeArea, orientation: orientation)
    case .wiiRemote: return shifted(wiiRemote, by: safeArea)
    case .wiiRemoteSideways: return shifted(wiiRemoteSideways, by: safeArea)
    case .wiiClassic: return shifted(wiiClassic, by: safeArea)
    }
  }

  static func layout(for group: TouchOverlayGroup, kind: TouchOverlayPadKind, orientation: TouchOverlayOrientation,
                     canvas: CGSize, safeArea: UIEdgeInsets) -> TouchOverlayGroupLayout? {
    layout(for: kind, orientation: orientation, canvas: canvas, safeArea: safeArea).first { $0.group == group }
  }

  /// Moves edge-anchored groups inward by the safe area: what the xibs' safe-area-relative
  /// constraints did. `.fillInset` groups (the IR surface) cover the whole pad on purpose.
  private static func shifted(_ layouts: [TouchOverlayGroupLayout], by safeArea: UIEdgeInsets) -> [TouchOverlayGroupLayout] {
    layouts.map { layout in
      let p = layout.placement
      let dx: CGFloat
      switch p.anchor {
      case .bottomLeading: dx = safeArea.left
      case .bottomTrailing: dx = safeArea.right
      case .bottomCenter: dx = (safeArea.left - safeArea.right) / 2
      case .fill, .fillInset: return layout
      }
      let placement = TouchOverlayPlacement(p.anchor, inset: CGPoint(x: p.inset.x + dx, y: p.inset.y + safeArea.bottom),
                                            size: p.size, margin: p.margin)
      return TouchOverlayGroupLayout(group: layout.group, placement: placement, controls: layout.controls)
    }
  }

  // MARK: GameCube (computed)

  /// Sizes at scale 1 (a ~390 pt-wide phone), in points. Every control is at least 44 pt on its
  /// short side, and round buttons get square frames so the art fills them.
  private enum GC {
    static let mainStick: CGFloat = 132
    static let cStick: CGFloat = 100
    static let dpad: CGFloat = 104
    static let a: CGFloat = 72
    static let b: CGFloat = 48
    /// X wraps A's right side (tall), Y its top (wide).
    static let kidneyLong: CGFloat = 64
    static let kidneyShort: CGFloat = 44
    static let shoulder = CGSize(width: 96, height: 44)
    static let z = CGSize(width: 80, height: 44)
    static let start = CGSize(width: 70, height: 44)
    /// Space between neighbouring controls and groups.
    static let gap: CGFloat = 8
    /// Space between the face buttons inside their cluster.
    static let faceGap: CGFloat = 6
    /// Minimum distance from a screen edge, on top of the safe area.
    static let edge: CGFloat = 8
    /// Extra lift above the home indicator so the lowest controls don't fight the system swipe.
    static let bottomGuard: CGFloat = 6
    /// In landscape the D-pad and C-stick sit beside-and-below the main stick and face buttons
    /// (the controller's own diagonal); portrait stacks them straight down to fit the width.
    static let landscapeDiagonal: CGFloat = 70
    /// Tall screens (iPad) keep the controls in a band at the bottom instead of spreading them up
    /// the whole side.
    static let maxBandHeight: CGFloat = 420
    static let referenceShortSide: CGFloat = 390
    static let maxScale: CGFloat = 1.35
  }

  private static func gameCube(canvas: CGSize, safeArea: UIEdgeInsets,
                               orientation: TouchOverlayOrientation) -> [TouchOverlayGroupLayout] {
    let w = canvas.width, h = canvas.height
    let u = min(max(min(w, h) / GC.referenceShortSide, 1), GC.maxScale)
    let gap = GC.gap * u
    let stick = GC.mainStick * u, cStick = GC.cStick * u, dpad = GC.dpad * u
    let shoulder = CGSize(width: GC.shoulder.width * u, height: GC.shoulder.height * u)
    let zSize = CGSize(width: GC.z.width * u, height: GC.z.height * u)
    let startSize = CGSize(width: GC.start.width * u, height: GC.start.height * u)
    let face = gameCubeFaceButtons(scale: u)

    let left = max(safeArea.left, GC.edge) + GC.edge
    let right = w - max(safeArea.right, GC.edge) - GC.edge
    let bottom = h - max(safeArea.bottom, GC.edge) - GC.bottomGuard
    // Portrait: the game is drawn aspect-fit at the top, so the controls start under it.
    let gameBottom = safeArea.top + (w - safeArea.left - safeArea.right) * 3 / 4
    let regionTop = orientation == .portrait ? gameBottom + gap : max(safeArea.top, GC.edge) + GC.edge
    let top = max(regionTop, bottom - GC.maxBandHeight * u)
    let diagonal = orientation == .landscape ? GC.landscapeDiagonal * u : 0

    // Left hand, bottom up: D-pad, main stick, L.
    let dpadCenter = CGPoint(x: left + stick / 2 + diagonal, y: bottom - dpad / 2)
    let stickCenter = CGPoint(x: left + stick / 2, y: bottom - dpad - gap - stick / 2)
    let lCenter = CGPoint(x: left + shoulder.width / 2,
                          y: max(top + shoulder.height / 2, stickCenter.y - stick / 2 - gap - shoulder.height / 2))

    // Right hand, bottom up: C-stick, face buttons, R over Z.
    let faceCenterX = right - face.size.width / 2
    let cStickCenter = CGPoint(x: faceCenterX - diagonal, y: bottom - cStick / 2)
    let faceCenter = CGPoint(x: faceCenterX, y: bottom - cStick - gap - face.size.height / 2)
    let rzSize = CGSize(width: shoulder.width, height: shoulder.height + gap + zSize.height)
    let rzCenter = CGPoint(x: right - rzSize.width / 2,
                           y: max(top + rzSize.height / 2, faceCenter.y - face.size.height / 2 - gap - rzSize.height / 2))

    let startCenter = CGPoint(x: w / 2, y: bottom - startSize.height / 2)

    func leading(_ center: CGPoint) -> TouchOverlayPlacement.Inset { .init(anchor: .bottomLeading, x: center.x, y: h - center.y) }
    func trailing(_ center: CGPoint) -> TouchOverlayPlacement.Inset { .init(anchor: .bottomTrailing, x: w - center.x, y: h - center.y) }

    return [
      single(.gcMainStick, leading(stickCenter), size: CGSize(width: stick, height: stick),
             kind: .stick(baseId: ID.gcMainStick), id: "gc.mainStick"),
      single(.gcDpad, leading(dpadCenter), size: CGSize(width: dpad, height: dpad),
             kind: .dpad(baseId: ID.gcDpadUp), id: "gc.dpad"),
      single(.gcCStick, trailing(cStickCenter), size: CGSize(width: cStick, height: cStick),
             kind: .stick(baseId: ID.gcCStick), id: "gc.cStick"),
      TouchOverlayGroupLayout(group: .gcFaceButtons, placement: trailing(faceCenter).placement(size: face.size),
                              controls: face.controls),
      TouchOverlayGroupLayout(group: .gcLeftShoulder, placement: leading(lCenter).placement(size: shoulder),
                              controls: [axisButton("gc.l", ID.gcTriggerL, 0, 0, size: shoulder)]),
      TouchOverlayGroupLayout(
        group: .gcRightShoulder, placement: trailing(rzCenter).placement(size: rzSize),
        controls: [axisButton("gc.r", ID.gcTriggerR, 0, 0, size: shoulder),
                   button("gc.z", ID.gcZ, (shoulder.width - zSize.width) / 2, shoulder.height + gap, size: zSize)]),
      TouchOverlayGroupLayout(group: .gcStart,
                              placement: TouchOverlayPlacement(.bottomCenter, inset: CGPoint(x: startCenter.x - w / 2, y: h - startCenter.y),
                                                               size: startSize),
                              controls: [button("gc.start", ID.gcStart, 0, 0, size: startSize)]),
    ]
  }

  /// The GameCube face buttons around a big A, as on the controller: B down-left, X wrapping the
  /// right side, Y wrapping the top. Frames are placed edge to edge with `faceGap` between them,
  /// so no two touch areas overlap.
  private static func gameCubeFaceButtons(scale u: CGFloat) -> (size: CGSize, controls: [TouchOverlayControl]) {
    let a = GC.a * u, b = GC.b * u, long = GC.kidneyLong * u, short = GC.kidneyShort * u, gap = GC.faceGap * u
    // Offsets of each button's CENTRE from A's centre.
    let bOffset = CGPoint(x: -(a / 2 + b / 2), y: a / 2 - b / 4)
    let xOffset = CGPoint(x: a / 2 + gap + short / 2, y: -gap)
    let yOffset = CGPoint(x: -gap / 2, y: -(a / 2 + gap + short / 2))
    let minX = min(bOffset.x - b / 2, yOffset.x - long / 2)
    let maxX = xOffset.x + short / 2
    let minY = yOffset.y - short / 2
    let maxY = max(bOffset.y + b / 2, a / 2, xOffset.y + long / 2)
    let origin = CGPoint(x: -minX, y: -minY) // A's centre in cluster coordinates
    func frame(_ offset: CGPoint, _ size: CGSize) -> CGRect {
      CGRect(x: origin.x + offset.x - size.width / 2, y: origin.y + offset.y - size.height / 2,
             width: size.width, height: size.height)
    }
    let controls = [
      TouchOverlayControl(id: "gc.a", kind: .button(id: ID.gcA), frame: frame(.zero, CGSize(width: a, height: a))),
      TouchOverlayControl(id: "gc.b", kind: .button(id: ID.gcB), frame: frame(bOffset, CGSize(width: b, height: b))),
      TouchOverlayControl(id: "gc.x", kind: .button(id: ID.gcX), frame: frame(xOffset, CGSize(width: short, height: long))),
      TouchOverlayControl(id: "gc.y", kind: .button(id: ID.gcY), frame: frame(yOffset, CGSize(width: long, height: short))),
    ]
    return (CGSize(width: maxX - minX, height: maxY - minY), controls)
  }

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
