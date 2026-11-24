// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import CoreGraphics
import Foundation
import SkinKitBezels

/// iCube's side of the shared TV bezels (SkinKit `docs/bezels.md`): a TV drawn around the game picture in
/// landscape, and the pause menu's strip that previews TVs over the paused game.
///
/// SkinKit owns the rules, the bundled TVs, the player's own bezels and the views. What is here is what only
/// iCube knows: where things are stored, which system is running, and how the emulation screen's state maps
/// onto the package's placement rule. iCube shows a TV the plain way, as an image with the picture in its
/// screen; nothing extra is drawn on the GPU.
enum ICubeBezels {
  /// `SystemIdentifier` raw values (PVSystems): the bundled TVs and The Bezel Project's table are keyed by them.
  static let gameCubeSystemID = "com.provenance.gamecube"
  static let wiiSystemID = "com.provenance.wii"

  /// Before every stored choice's key, in the app's `snake_case` defaults style (`bezel_chosenBezel`, ...).
  static let settingsKeyPrefix = "bezel_"
  /// Sent with The Bezel Project's list requests: the app's name, nothing about the player.
  static let userAgent = "iCube"
  /// The `PauseArbiter` reason that keeps the game paused under the switcher strip.
  static let pauseReason = "bezel-switcher"
  /// The picture's shape until the core reports one.
  static let fallbackPictureAspect: CGFloat = 4.0 / 3.0
  /// Where the stored seat lives. iCube's own key; the package stores nothing under this name.
  static let seatKey = settingsKeyPrefix + "seat"

  /// Where the player sits in front of a built-in TV: how much of the room is drawn. Back until the player picks
  /// another seat, and for a stored value this build does not know.
  static func seat(in defaults: UserDefaults = .standard) -> TVBezelSeat {
    defaults.string(forKey: seatKey).flatMap(TVBezelSeat.init(rawValue:)) ?? .back
  }

  static func setSeat(_ seat: TVBezelSeat, in defaults: UserDefaults = .standard) {
    defaults.set(seat.rawValue, forKey: seatKey)
  }

  /// `bezel` laid out as a plain image over `container`. A built-in TV's room is drawn for the container's shape
  /// from `seat`, so it covers the screen on a phone and a tablet alike; draw its artwork on `TVBezelLayout.canvas`.
  static func layout(bezel: TVBezel, container: CGSize, pictureAspect: CGSize,
                     seat: TVBezelSeat = ICubeBezels.seat()) -> TVBezelLayout? {
    TVBezelLayout(bezel: bezel, container: container, pictureAspect: pictureAspect, seat: seat)
  }

  private static let log = ICubeLog.logger("Bezels")
  private static let lock = NSLock()
  private static var isConfigured = false

  /// Sets the package's environment. Idempotent; call it at launch, before anything else of the package is used.
  static func configure() {
    lock.lock()
    defer { lock.unlock() }
    guard !isConfigured else { return }
    isConfigured = true

    BezelEnvironment.current = BezelEnvironment(
      libraryRootURL: BezelEnvironment.defaultLibraryRootURL,
      userAgent: userAgent,
      settings: UserDefaultsBezelSettings(prefix: settingsKeyPrefix),
      systems: {
        [BezelEnvironment.System(id: gameCubeSystemID, name: "GameCube"),
         BezelEnvironment.System(id: wiiSystemID, name: "Wii")]
      })
    BezelLog.handler = { level, message in
      switch level {
      case .info: log.info("\(message)")
      case .warning: log.warning("\(message)")
      case .error: log.error("\(message)")
      }
    }
  }

  static func systemID(isWii: Bool) -> String { isWii ? wiiSystemID : gameCubeSystemID }

  /// The key a game's own TV is stored under: the running core's game ID, or the library's while the core is
  /// still booting. `nil` (no "this game only") when neither is known.
  static func gameKey(running: String, library: String) -> String? {
    if !running.isEmpty { return running }
    return library.isEmpty ? nil : library
  }

  // MARK: - Whether a TV may show

  /// What the emulation screen knows that decides whether a TV may be drawn around the picture.
  struct ScreenState: Equatable {
    /// The whole screen the game is laid out on, safe areas included.
    var canvas: CGSize = .zero
    /// The on-screen controls are showing.
    var touchControlsShown = false
    /// What shows is a Delta or Manic skin, which frames the picture itself.
    var skinShown = false
    /// A hardware controller is connected.
    var controllerConnected = false
    /// The picture is on an external display, not on this screen.
    var onExternalDisplay = false
    /// The layout editor is open over the game.
    var editingLayout = false
  }

  static func controls(_ state: ScreenState) -> GameplayBezelPlacement.Controls {
    if state.touchControlsShown { return state.skinShown ? .skin : .generated }
    return state.controllerConnected ? .hiddenByController : .bare
  }

  /// The package's placement inputs for the screen as it is now.
  /// - Parameter choiceIsAutomatic: `Resolution.isAutomatic` of the TV that would show.
  static func placementInputs(_ state: ScreenState, choiceIsAutomatic: Bool) -> GameplayBezelPlacement.Inputs {
    GameplayBezelPlacement.Inputs(
      isAppleTV: false,
      isLandscape: state.canvas.width > state.canvas.height,
      controls: controls(state),
      layoutSupportsTV: !state.onExternalDisplay,
      choiceIsAutomatic: choiceIsAutomatic,
      editingLayout: state.editingLayout)
  }

  static func showsTV(_ state: ScreenState, choiceIsAutomatic: Bool) -> Bool {
    GameplayBezelPlacement.showsTV(placementInputs(state, choiceIsAutomatic: choiceIsAutomatic))
  }

  /// Whether the pause menu offers the Bezels item: a TV the player chose could show right now.
  static func offersSwitcher(_ state: ScreenState) -> Bool {
    GameplayBezelPlacement.offersSwitcher(placementInputs(state, choiceIsAutomatic: false))
  }

  // MARK: - Where the game surface goes

  /// The largest rect of `aspect` (width / height) that fits `rect`, centred in it.
  static func aspectFit(aspect: CGFloat, in rect: CGRect) -> CGRect {
    guard aspect > 0, aspect.isFinite, rect.width > 0, rect.height > 0 else { return rect }
    let size = rect.width / rect.height > aspect
      ? CGSize(width: rect.height * aspect, height: rect.height)
      : CGSize(width: rect.width, height: rect.width / aspect)
    return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
  }

  /// How far two aspect ratios may differ and still be the same shape.
  static let aspectTolerance: CGFloat = 0.01

  /// The frame to give the game surface so that the picture lands on `picture`, while the surface still shows
  /// a frame drawn when it had the shape `drawnAspect`.
  ///
  /// The core draws the picture aspect-fitted inside its surface and does not draw again while paused, so
  /// Core Animation stretches the last frame over whatever frame the surface is given. Previewing a TV over a
  /// paused game moves the surface: keeping the shape it was drawn at keeps the picture undistorted, and the
  /// caller clips the surface to `picture` to hide the bars that came with the old shape. With no `drawnAspect`,
  /// or one that is the picture's own shape, the surface is the picture.
  static func surfaceFrame(showing picture: CGRect, drawnAspect: CGFloat?) -> CGRect {
    guard let drawnAspect, drawnAspect > 0, drawnAspect.isFinite, picture.width > 0, picture.height > 0 else { return picture }
    let pictureAspect = picture.width / picture.height
    guard abs(drawnAspect - pictureAspect) > aspectTolerance * pictureAspect else { return picture }
    let size = drawnAspect > pictureAspect
      ? CGSize(width: picture.height * drawnAspect, height: picture.height)
      : CGSize(width: picture.width, height: picture.width / drawnAspect)
    return CGRect(x: picture.midX - size.width / 2, y: picture.midY - size.height / 2, width: size.width, height: size.height)
  }
}
#endif
