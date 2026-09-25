// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import CoreGraphics
import Foundation

// Phase 1 of the programmatic touch overlay (docs/superpowers/specs/
// 2026-09-24-programmatic-touch-overlay-design.md): the layout MODEL only. Nothing here draws or
// dispatches touches; the xib pads keep running until phase 3. Every id below is a raw
// `TCButtonType` value, exactly as the xib controls store them (`TCButton.controllerButton`,
// `TCJoystick.joystickType`, `TCDirectionalPad.directionalPadType`), so the profiles in
// Data/Sys/Profiles/{GCPad,Wiimote}/Touchscreen.ini keep matching.

/// Which pad the overlay renders. Mirrors `makeWiiPadView()` in EmulationScreen+TouchAndMotion:
/// a Classic Controller wins over sideways, sideways over the upright remote.
enum TouchOverlayPadKind: String, CaseIterable, Codable, Sendable {
  case gameCube
  case wiiRemote
  case wiiRemoteSideways
  case wiiClassic

  static func wii(classicActive: Bool, sideways: Bool) -> TouchOverlayPadKind {
    if classicActive { return .wiiClassic }
    return sideways ? .wiiRemoteSideways : .wiiRemote
  }
}

enum TouchOverlayOrientation: String, CaseIterable, Codable, Sendable {
  case portrait
  case landscape

  init(isPortrait: Bool) { self = isPortrait ? .portrait : .landscape }
}

/// A movable control GROUP, the atomic unit the editor drags. Each pad kind instantiates the
/// subset it needs (`TouchOverlayDefaults`). Groups follow the clusters the xibs actually draw,
/// not the console's logical grouping: GameCube L and Start share the left shoulder strip, Z and
/// R the right one; the sideways remote's A/1/2/+/- form one cluster.
enum TouchOverlayGroup: String, CaseIterable, Codable, Sendable {
  // GameCube
  case gcDpad, gcMainStick, gcCStick, gcFaceButtons, gcLeftShoulder, gcRightShoulder
  // Wii Remote, upright
  case wiiDpad, wiiAB, wiiOneTwo, wiiMinusPlusHome, wiiIRPad
  // Wii Remote, sideways
  case sidewaysB, sidewaysFaceCluster, sidewaysHome
  // Nunchuk
  case nunchukStick, nunchukC, nunchukZ
  // Classic Controller
  case classicDpad, classicLeftStick, classicRightStick, classicFaceButtons
  case classicLeftShoulder, classicRightShoulder, classicMinusPlusHome
}

/// What a control inside a group does when touched. Raw `TCButtonType` ids (§6.2 of the design).
enum TouchOverlayControlKind: Equatable, Sendable {
  /// `setButtonStateFor(id)`.
  case button(id: Int)
  /// A `TCButton` with `isAxis`: an analog trigger written as 1.0 / 0.0 through `setAxisValueFor(id)`.
  case axisButton(id: Int)
  /// A stick writing four half-axes `baseId + 1 ... baseId + 4` (`TouchOverlayInput.stickWrites`).
  case stick(baseId: Int)
  /// A D-pad writing four buttons `baseId + 0 ... baseId + 3` in Up/Down/Left/Right order.
  case dpad(baseId: Int)
  /// The Wii IR drag/follow surface (phase 3 ports `TCWiiPad.handleLongPress` onto it).
  case irSurface
}

/// One control inside a group. `frame` is in the group's own box coordinates (origin top-left).
struct TouchOverlayControl: Equatable, Sendable {
  let id: String
  let kind: TouchOverlayControlKind
  let frame: CGRect
}

/// A group's default placement plus its controls.
struct TouchOverlayGroupLayout: Sendable {
  let group: TouchOverlayGroup
  let placement: TouchOverlayPlacement
  let controls: [TouchOverlayControl]

  var size: CGSize { placement.size }
}
#endif
