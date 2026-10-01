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
    case .wiiRemote: return wiiRemote(canvas: canvas, safeArea: safeArea, orientation: orientation)
    case .wiiRemoteSideways: return shifted(wiiRemoteSideways, by: safeArea)
    case .wiiClassic: return wiiClassic(canvas: canvas, safeArea: safeArea, orientation: orientation)
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

  // MARK: Computed layouts (GameCube, Wii Remote + Nunchuk, Classic Controller)

  /// Spacing shared by the computed layouts, at scale 1 (a ~390 pt-wide phone), in points.
  private enum Spacing {
    /// Space between neighbouring controls and groups.
    static let gap: CGFloat = 8
    /// Minimum distance from a screen edge, on top of the safe area.
    static let edge: CGFloat = 8
    /// Extra lift above the home indicator so the lowest controls don't fight the system swipe.
    static let bottomGuard: CGFloat = 6
    /// In landscape the lower stick / D-pad sits beside-and-below the one above it (the
    /// controllers' own diagonal); portrait stacks them straight down to fit the width.
    static let landscapeDiagonal: CGFloat = 70
    static let referenceShortSide: CGFloat = 390
    static let maxScale: CGFloat = 1.35
    /// Round "system" buttons (Wii −/HOME/+): the smallest comfortable touch target.
    static let systemButton: CGFloat = 44
  }

  /// The usable edges of one screen and the scale the computed layouts draw at. Every control is
  /// at least 44 pt on its short side, and round buttons get square frames so the art fills them.
  private struct Screen {
    let w: CGFloat
    let h: CGFloat
    let u: CGFloat
    let gap: CGFloat
    let left: CGFloat
    let right: CGFloat
    let bottom: CGFloat
    /// Portrait: just under the game picture (drawn aspect-fit at the top). Landscape: the top edge.
    let regionTop: CGFloat
    let diagonal: CGFloat
    let orientation: TouchOverlayOrientation

    init(canvas: CGSize, safeArea: UIEdgeInsets, orientation: TouchOverlayOrientation) {
      w = canvas.width
      h = canvas.height
      u = min(max(min(w, h) / Spacing.referenceShortSide, 1), Spacing.maxScale)
      gap = Spacing.gap * u
      left = max(safeArea.left, Spacing.edge) + Spacing.edge
      right = w - max(safeArea.right, Spacing.edge) - Spacing.edge
      bottom = h - max(safeArea.bottom, Spacing.edge) - Spacing.bottomGuard
      let gameBottom = safeArea.top + (w - safeArea.left - safeArea.right) * 3 / 4
      regionTop = orientation == .portrait ? gameBottom + gap : max(safeArea.top, Spacing.edge) + Spacing.edge
      diagonal = orientation == .landscape ? Spacing.landscapeDiagonal * u : 0
      self.orientation = orientation
    }

    func size(_ side: CGFloat) -> CGSize { CGSize(width: side * u, height: side * u) }
    func size(_ size: CGSize) -> CGSize { CGSize(width: size.width * u, height: size.height * u) }

    func leading(_ center: CGPoint) -> TouchOverlayPlacement.Inset { .init(anchor: .bottomLeading, x: center.x, y: h - center.y) }
    func trailing(_ center: CGPoint) -> TouchOverlayPlacement.Inset { .init(anchor: .bottomTrailing, x: w - center.x, y: h - center.y) }
    func centered(_ center: CGPoint) -> TouchOverlayPlacement.Inset { .init(anchor: .bottomCenter, x: center.x - w / 2, y: h - center.y) }
  }

  /// Controls laid out left to right, `gap` apart, vertically centred in a row as tall as the
  /// tallest one. Returns the row's size and each control's frame inside it.
  private static func row(_ sizes: [CGSize], gap: CGFloat) -> (size: CGSize, frames: [CGRect]) {
    let height = sizes.map(\.height).max() ?? 0
    var x: CGFloat = 0
    var frames: [CGRect] = []
    for size in sizes {
      frames.append(CGRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height))
      x += size.width + gap
    }
    return (CGSize(width: max(0, x - gap), height: height), frames)
  }

  /// The same, top to bottom, horizontally centred.
  private static func column(_ sizes: [CGSize], gap: CGFloat) -> (size: CGSize, frames: [CGRect]) {
    let r = row(sizes.map { CGSize(width: $0.height, height: $0.width) }, gap: gap)
    return (CGSize(width: r.size.height, height: r.size.width),
            r.frames.map { CGRect(x: $0.minY, y: $0.minX, width: $0.height, height: $0.width) })
  }

  private static func group(_ group: TouchOverlayGroup, _ inset: TouchOverlayPlacement.Inset,
                            size: CGSize, controls: [TouchOverlayControl]) -> TouchOverlayGroupLayout {
    TouchOverlayGroupLayout(group: group, placement: inset.placement(size: size), controls: controls)
  }

  // MARK: GameCube

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
    /// Space between the face buttons inside their cluster.
    static let faceGap: CGFloat = 6
    /// Tall screens (iPad) keep the controls in a band at the bottom instead of spreading them up
    /// the whole side.
    static let maxBandHeight: CGFloat = 420
  }

  private static func gameCube(canvas: CGSize, safeArea: UIEdgeInsets,
                               orientation: TouchOverlayOrientation) -> [TouchOverlayGroupLayout] {
    let s = Screen(canvas: canvas, safeArea: safeArea, orientation: orientation)
    let gap = s.gap, left = s.left, right = s.right, bottom = s.bottom
    let stick = GC.mainStick * s.u, cStick = GC.cStick * s.u, dpad = GC.dpad * s.u
    let shoulder = s.size(GC.shoulder), zSize = s.size(GC.z), startSize = s.size(GC.start)
    let face = gameCubeFaceButtons(scale: s.u)
    let top = max(s.regionTop, bottom - GC.maxBandHeight * s.u)

    // Left hand, bottom up: D-pad, main stick, L.
    let dpadCenter = CGPoint(x: left + stick / 2 + s.diagonal, y: bottom - dpad / 2)
    let stickCenter = CGPoint(x: left + stick / 2, y: bottom - dpad - gap - stick / 2)
    let lCenter = CGPoint(x: left + shoulder.width / 2,
                          y: max(top + shoulder.height / 2, stickCenter.y - stick / 2 - gap - shoulder.height / 2))

    // Right hand, bottom up: C-stick, face buttons, R over Z.
    let faceCenterX = right - face.size.width / 2
    let cStickCenter = CGPoint(x: faceCenterX - s.diagonal, y: bottom - cStick / 2)
    let faceCenter = CGPoint(x: faceCenterX, y: bottom - cStick - gap - face.size.height / 2)
    let rzSize = CGSize(width: shoulder.width, height: shoulder.height + gap + zSize.height)
    let rzCenter = CGPoint(x: right - rzSize.width / 2,
                           y: max(top + rzSize.height / 2, faceCenter.y - face.size.height / 2 - gap - rzSize.height / 2))

    let startCenter = CGPoint(x: s.w / 2, y: bottom - startSize.height / 2)

    return [
      single(.gcMainStick, s.leading(stickCenter), size: CGSize(width: stick, height: stick),
             kind: .stick(baseId: ID.gcMainStick), id: "gc.mainStick"),
      single(.gcDpad, s.leading(dpadCenter), size: CGSize(width: dpad, height: dpad),
             kind: .dpad(baseId: ID.gcDpadUp), id: "gc.dpad"),
      single(.gcCStick, s.trailing(cStickCenter), size: CGSize(width: cStick, height: cStick),
             kind: .stick(baseId: ID.gcCStick), id: "gc.cStick"),
      group(.gcFaceButtons, s.trailing(faceCenter), size: face.size, controls: face.controls),
      group(.gcLeftShoulder, s.leading(lCenter), size: shoulder,
            controls: [axisButton("gc.l", ID.gcTriggerL, 0, 0, size: shoulder)]),
      group(.gcRightShoulder, s.trailing(rzCenter), size: rzSize,
            controls: [axisButton("gc.r", ID.gcTriggerR, 0, 0, size: shoulder),
                       button("gc.z", ID.gcZ, (shoulder.width - zSize.width) / 2, shoulder.height + gap, size: zSize)]),
      group(.gcStart, s.centered(startCenter), size: startSize,
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

  // MARK: Wii Remote + Nunchuk, upright

  private enum WiiRemote {
    static let nunchukStick: CGFloat = 132
    static let dpad: CGFloat = 104
    static let a: CGFloat = 72
    static let b: CGFloat = 56
    /// 1, 2 and the Nunchuk's C.
    static let small: CGFloat = 48
    static let z = CGSize(width: 80, height: 44)
  }

  /// Left hand: the Nunchuk stick at rest, the D-pad above it, Z and C above that. Right hand: A
  /// with B above it, 1 over 2 beside them, and −/HOME/+ in a row on top. The IR pointer surface
  /// covers the rest of the pad, under everything.
  private static func wiiRemote(canvas: CGSize, safeArea: UIEdgeInsets,
                                orientation: TouchOverlayOrientation) -> [TouchOverlayGroupLayout] {
    let s = Screen(canvas: canvas, safeArea: safeArea, orientation: orientation)
    let gap = s.gap
    let stick = WiiRemote.nunchukStick * s.u, dpad = WiiRemote.dpad * s.u
    let zSize = s.size(WiiRemote.z), cSize = s.size(WiiRemote.small)

    let stickCenter = CGPoint(x: s.left + stick / 2 + s.diagonal, y: s.bottom - stick / 2)
    let dpadCenter = CGPoint(x: s.left + dpad / 2, y: s.bottom - stick - gap - dpad / 2)
    let zcY = s.bottom - stick - gap - dpad - gap - zSize.height / 2
    let zCenter = CGPoint(x: s.left + zSize.width / 2, y: zcY)
    let cCenter = CGPoint(x: s.left + zSize.width + gap + cSize.width / 2, y: zcY)

    let ab = column([s.size(WiiRemote.b), s.size(WiiRemote.a)], gap: gap)
    let oneTwo = column([s.size(WiiRemote.small), s.size(WiiRemote.small)], gap: gap)
    let system = row(Array(repeating: s.size(Spacing.systemButton), count: 3), gap: gap)
    let abCenter = CGPoint(x: s.right - ab.size.width / 2, y: s.bottom - ab.size.height / 2)
    let oneTwoCenter = CGPoint(x: s.right - ab.size.width - gap - oneTwo.size.width / 2, y: s.bottom - oneTwo.size.height / 2)
    let systemCenter = CGPoint(x: s.right - system.size.width / 2,
                               y: s.bottom - max(ab.size.height, oneTwo.size.height) - gap - system.size.height / 2)

    return [
      single(.nunchukStick, s.leading(stickCenter), size: CGSize(width: stick, height: stick),
             kind: .stick(baseId: ID.nunchukStick), id: "nunchuk.stick"),
      single(.wiiDpad, s.leading(dpadCenter), size: CGSize(width: dpad, height: dpad),
             kind: .dpad(baseId: ID.wiiDpadUp), id: "wii.dpad"),
      single(.nunchukZ, s.leading(zCenter), size: zSize, kind: .button(id: ID.nunchukZ), id: "nunchuk.z"),
      single(.nunchukC, s.leading(cCenter), size: cSize, kind: .button(id: ID.nunchukC), id: "nunchuk.c"),
      group(.wiiAB, s.trailing(abCenter), size: ab.size, controls: [
        TouchOverlayControl(id: "wii.b", kind: .button(id: ID.wiiB), frame: ab.frames[0]),
        TouchOverlayControl(id: "wii.a", kind: .button(id: ID.wiiA), frame: ab.frames[1]),
      ]),
      group(.wiiOneTwo, s.trailing(oneTwoCenter), size: oneTwo.size, controls: [
        TouchOverlayControl(id: "wii.one", kind: .button(id: ID.wiiOne), frame: oneTwo.frames[0]),
        TouchOverlayControl(id: "wii.two", kind: .button(id: ID.wiiTwo), frame: oneTwo.frames[1]),
      ]),
      group(.wiiMinusPlusHome, s.trailing(systemCenter), size: system.size, controls: [
        TouchOverlayControl(id: "wii.minus", kind: .button(id: ID.wiiMinus), frame: system.frames[0]),
        TouchOverlayControl(id: "wii.home", kind: .button(id: ID.wiiHome), frame: system.frames[1]),
        TouchOverlayControl(id: "wii.plus", kind: .button(id: ID.wiiPlus), frame: system.frames[2]),
      ]),
      // The drag/follow surface (phase 3): the whole pad inset by `irPadMargin`, movable/resizable
      // like any other group (§2.4) instead of the phase-2 placeholder's literal full bounds.
      TouchOverlayGroupLayout(
        group: .wiiIRPad,
        placement: TouchOverlayPlacement(.fillInset, margin: irPadMargin),
        controls: [TouchOverlayControl(id: "wii.ir", kind: .irSurface, frame: .zero)]),
    ]
  }

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

  // MARK: Wii Remote + Classic Controller

  private enum Classic {
    static let stick: CGFloat = 124
    static let dpad: CGFloat = 104
    static let face: CGFloat = 48
    /// Centre-to-centre distance from the middle of the diamond to each face button.
    static let faceSpacing: CGFloat = 52
    static let shoulder = CGSize(width: 64, height: 44)
    static let shoulderGap: CGFloat = 6
  }

  /// Laid out like the controller: D-pad over the left stick (which sits inward in landscape), the
  /// face-button diamond over the right stick, L/ZL and ZR/R side by side above them, and −/HOME/+
  /// between the sticks in landscape or above everything in portrait. On a short portrait screen
  /// (iPhone SE) the top row may sit over the bottom of the game picture.
  private static func wiiClassic(canvas: CGSize, safeArea: UIEdgeInsets,
                                 orientation: TouchOverlayOrientation) -> [TouchOverlayGroupLayout] {
    let s = Screen(canvas: canvas, safeArea: safeArea, orientation: orientation)
    let gap = s.gap
    let stick = Classic.stick * s.u, dpad = Classic.dpad * s.u
    let shoulder = s.size(Classic.shoulder)
    let shoulders = row([shoulder, shoulder], gap: Classic.shoulderGap * s.u)
    let system = row(Array(repeating: s.size(Spacing.systemButton), count: 3), gap: gap)
    let diamond = classicFaceButtons(scale: s.u)

    // Left: stick at rest, D-pad above, L | ZL above that.
    let leftStickCenter = CGPoint(x: s.left + stick / 2 + s.diagonal, y: s.bottom - stick / 2)
    let dpadCenter = CGPoint(x: s.left + dpad / 2, y: s.bottom - stick - gap - dpad / 2)
    let leftShoulderTop = s.bottom - stick - gap - dpad - gap - shoulders.size.height
    let leftShoulderCenter = CGPoint(x: s.left + shoulders.size.width / 2, y: leftShoulderTop + shoulders.size.height / 2)

    // Right: stick at rest, face diamond above, ZR | R above that.
    let rightStickCenter = CGPoint(x: s.right - stick / 2 - s.diagonal, y: s.bottom - stick / 2)
    let diamondCenter = CGPoint(x: s.right - diamond.size.width / 2, y: s.bottom - stick - gap - diamond.size.height / 2)
    let rightShoulderTop = s.bottom - stick - gap - diamond.size.height - gap - shoulders.size.height
    let rightShoulderCenter = CGPoint(x: s.right - shoulders.size.width / 2, y: rightShoulderTop + shoulders.size.height / 2)

    // Landscape has room between the sticks; portrait doesn't, so the row goes on top.
    let systemCenter = orientation == .landscape
      ? CGPoint(x: s.w / 2, y: s.bottom - system.size.height / 2)
      : CGPoint(x: s.w / 2, y: min(leftShoulderTop, rightShoulderTop) - gap - system.size.height / 2)

    return [
      single(.classicLeftStick, s.leading(leftStickCenter), size: CGSize(width: stick, height: stick),
             kind: .stick(baseId: ID.classicLeftStick), id: "classic.leftStick"),
      single(.classicRightStick, s.trailing(rightStickCenter), size: CGSize(width: stick, height: stick),
             kind: .stick(baseId: ID.classicRightStick), id: "classic.rightStick"),
      single(.classicDpad, s.leading(dpadCenter), size: CGSize(width: dpad, height: dpad),
             kind: .dpad(baseId: ID.classicDpadUp), id: "classic.dpad"),
      group(.classicFaceButtons, s.trailing(diamondCenter), size: diamond.size, controls: diamond.controls),
      group(.classicLeftShoulder, s.leading(leftShoulderCenter), size: shoulders.size, controls: [
        axisButton("classic.l", ID.classicTriggerL, shoulders.frames[0].minX, 0, size: shoulder),
        button("classic.zl", ID.classicZL, shoulders.frames[1].minX, 0, size: shoulder),
      ]),
      group(.classicRightShoulder, s.trailing(rightShoulderCenter), size: shoulders.size, controls: [
        button("classic.zr", ID.classicZR, shoulders.frames[0].minX, 0, size: shoulder),
        axisButton("classic.r", ID.classicTriggerR, shoulders.frames[1].minX, 0, size: shoulder),
      ]),
      group(.classicMinusPlusHome, s.centered(systemCenter), size: system.size, controls: [
        TouchOverlayControl(id: "classic.minus", kind: .button(id: ID.classicMinus), frame: system.frames[0]),
        TouchOverlayControl(id: "classic.home", kind: .button(id: ID.classicHome), frame: system.frames[1]),
        TouchOverlayControl(id: "classic.plus", kind: .button(id: ID.classicPlus), frame: system.frames[2]),
      ]),
    ]
  }

  /// X top, Y left, A right, B bottom, as on the Classic Controller.
  private static func classicFaceButtons(scale u: CGFloat) -> (size: CGSize, controls: [TouchOverlayControl]) {
    let side = Classic.face * u, d = Classic.faceSpacing * u
    let center = d + side / 2
    func frame(_ dx: CGFloat, _ dy: CGFloat) -> CGRect {
      CGRect(x: center + dx - side / 2, y: center + dy - side / 2, width: side, height: side)
    }
    let controls = [
      TouchOverlayControl(id: "classic.x", kind: .button(id: ID.classicX), frame: frame(0, -d)),
      TouchOverlayControl(id: "classic.y", kind: .button(id: ID.classicY), frame: frame(-d, 0)),
      TouchOverlayControl(id: "classic.a", kind: .button(id: ID.classicA), frame: frame(d, 0)),
      TouchOverlayControl(id: "classic.b", kind: .button(id: ID.classicB), frame: frame(0, d)),
    ]
    return (CGSize(width: center * 2, height: center * 2), controls)
  }
}
#endif
