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

/// `TouchOverlayView`'s editing state (task item 1, design §7/§9). A single enum rather than two
/// independent `Bool`s ("editing the layout" / "editing the IR area") so the §9 risk — "IR-area
/// edit vs layout edit: confirm entering one visibly disables the other" — is answered
/// STRUCTURALLY: there is exactly one `TouchOverlayEditMode` value at a time, so there is no state
/// in which both a `.layout`-style "every group is draggable" chrome AND an `.irArea`-style
/// "only the IR pad is" chrome can be showing at once. The "Edit Layout…" and "Edit IR Area…"
/// Settings rows each open `TouchOverlayView` already seeded into the matching mode
/// (`initialEditMode:`); there is no in-overlay control that switches between them.
enum TouchOverlayEditMode: Equatable, Sendable, CaseIterable {
  case none
  case layout
  case irArea

  /// True whenever ANY edit mode is active. Every group's own input must be suppressed in BOTH
  /// `.layout` and `.irArea` — not just the group(s) `showsChrome(for:)` makes editable — so a
  /// face button doesn't stay live and tappable underneath the editor while the user is dragging
  /// the IR pad's rectangle (or vice versa). Kept separate from `showsChrome` for exactly this
  /// reason: they used to be the same `Bool` (`PositionedTouchGroup`'s old single `isEditing`),
  /// which is what made the two modes' input isolation easy to get wrong.
  var inputSuppressed: Bool { self != .none }

  /// Whether `group` shows the editor's drag/resize chrome in this mode.
  ///
  /// `.layout` excludes `wiiIRPad` specifically: that group's `.layout`-mode chrome used to be
  /// the SAME uniform corner handle every other group gets, clamped only to
  /// `TouchOverlayLayoutStore.scaleRange` (0.5...2.0) — fine for a small fixed-size button, but on
  /// a `.fillInset` base (already most of the screen) that upper bound produces a box roughly 4x
  /// the overlay's area, with its resize handle dragged off-screen and only "Reset" able to
  /// recover it. `.irArea` mode's bounds-aware `clampFillInsetScale` (via `resizeAxes`) is the
  /// ONLY way to resize this group now, which also makes the two modes fully disjoint PER GROUP,
  /// not just "one mode active at a time" — the literal reading of design §9's "vice versa".
  func showsChrome(for group: TouchOverlayGroup) -> Bool {
    switch self {
    case .none: return false
    case .layout: return group != .wiiIRPad
    case .irArea: return group == .wiiIRPad
    }
  }
}
#endif
