// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SkinKitBezelsUI
import XCTest

@testable import iCube

/// iCube's glue for the shared TV bezels: how the emulation screen's state maps onto SkinKit's placement rule,
/// where the game surface goes while a TV is previewed over a paused game, and the strip's controller input.
/// The rules themselves are tested in SkinKit.
final class GameplayBezelTests: XCTestCase {
  private static let landscape = CGSize(width: 852, height: 393)
  private static let portrait = CGSize(width: 393, height: 852)

  private func state(canvas: CGSize = GameplayBezelTests.landscape, touch: Bool = false, skin: Bool = false,
                     controller: Bool = false, external: Bool = false, editing: Bool = false) -> ICubeBezels.ScreenState {
    ICubeBezels.ScreenState(canvas: canvas, touchControlsShown: touch, skinShown: skin, controllerConnected: controller,
                            onExternalDisplay: external, editingLayout: editing)
  }

  // MARK: - Placement

  func test_controls_followWhatIsOnScreen() {
    XCTAssertEqual(ICubeBezels.controls(state(touch: true)), .generated)
    XCTAssertEqual(ICubeBezels.controls(state(touch: true, skin: true)), .skin)
    XCTAssertEqual(ICubeBezels.controls(state(controller: true)), .hiddenByController)
    XCTAssertEqual(ICubeBezels.controls(state()), .bare)
    // The on-screen controls stay up beside a controller when the player assigned them a port.
    XCTAssertEqual(ICubeBezels.controls(state(touch: true, controller: true)), .generated)
    // A skin is picked but the on-screen controls are hidden: nothing frames the picture.
    XCTAssertEqual(ICubeBezels.controls(state(skin: true, controller: true)), .hiddenByController)
  }

  func test_placementInputs_readTheScreen() {
    let inputs = ICubeBezels.placementInputs(state(touch: true, editing: true), choiceIsAutomatic: true)
    XCTAssertEqual(inputs, GameplayBezelPlacement.Inputs(isAppleTV: false, isLandscape: true, controls: .generated,
                                                         layoutSupportsTV: true, choiceIsAutomatic: true, editingLayout: true))
    XCTAssertFalse(ICubeBezels.placementInputs(state(canvas: GameplayBezelTests.portrait), choiceIsAutomatic: false).isLandscape)
    XCTAssertFalse(ICubeBezels.placementInputs(state(external: true), choiceIsAutomatic: false).layoutSupportsTV)
    // A square window is not landscape: the automatic TV needs room beside the picture.
    XCTAssertFalse(ICubeBezels.placementInputs(state(canvas: CGSize(width: 500, height: 500)), choiceIsAutomatic: true).isLandscape)
  }

  func test_automaticTV_showsInLandscapeWithAControllerOrGeneratedControls() {
    XCTAssertTrue(ICubeBezels.showsTV(state(controller: true), choiceIsAutomatic: true))
    XCTAssertTrue(ICubeBezels.showsTV(state(touch: true), choiceIsAutomatic: true))
  }

  func test_noTV_withASkin_inPortrait_onAnExternalDisplay_orWhileEditing() {
    XCTAssertFalse(ICubeBezels.showsTV(state(touch: true, skin: true), choiceIsAutomatic: true))
    XCTAssertFalse(ICubeBezels.showsTV(state(canvas: GameplayBezelTests.portrait, controller: true), choiceIsAutomatic: true))
    XCTAssertFalse(ICubeBezels.showsTV(state(canvas: GameplayBezelTests.portrait, touch: true), choiceIsAutomatic: true))
    XCTAssertFalse(ICubeBezels.showsTV(state(controller: true, external: true), choiceIsAutomatic: true))
    XCTAssertFalse(ICubeBezels.showsTV(state(touch: true, editing: true), choiceIsAutomatic: true))
  }

  func test_switcher_isOfferedWhereAChosenTVCouldShow() {
    XCTAssertTrue(ICubeBezels.offersSwitcher(state(touch: true)))
    XCTAssertTrue(ICubeBezels.offersSwitcher(state(controller: true)))
    // In portrait a chosen TV shows once a controller has hidden the on-screen controls.
    XCTAssertTrue(ICubeBezels.offersSwitcher(state(canvas: GameplayBezelTests.portrait, controller: true)))
    XCTAssertFalse(ICubeBezels.offersSwitcher(state(canvas: GameplayBezelTests.portrait, touch: true)))
    XCTAssertFalse(ICubeBezels.offersSwitcher(state(touch: true, skin: true)))
    XCTAssertFalse(ICubeBezels.offersSwitcher(state(controller: true, external: true)))
  }

  // MARK: - The package inside the app

  /// A built-in TV's room is drawn for the screen's shape, so it covers a phone and a tablet alike.
  @MainActor
  func testABuiltInTVCoversTheScreenOnPhoneAndTablet() throws {
    ICubeBezels.configure()
    let bezel = try XCTUnwrap(TVBezelCatalog.bezel(id: "living-room-tv"))
    for container in [CGSize(width: 844, height: 390), CGSize(width: 1194, height: 834), CGSize(width: 1920, height: 1080)] {
      let layout = try XCTUnwrap(ICubeBezels.layout(bezel: bezel, container: container, pictureAspect: CGSize(width: 4, height: 3)),
                                 "\(container)")
      let bounds = CGRect(origin: .zero, size: container)
      XCTAssertEqual(layout.artworkFrame, bounds, "\(container)")
      XCTAssertTrue(bounds.contains(layout.screenFrame), "\(container)")
      XCTAssertEqual(layout.screenFrame.midX, bounds.midX, accuracy: 0.5, "\(container)")
      XCTAssertNotNil(layout.canvas, "\(container)")
    }
  }

  /// With nothing chosen, a GameCube game gets a bundled TV, and that TV lays out on a phone in landscape with
  /// the picture inside the screen. Fails if the package's bundled TVs did not make it into the app.
  @MainActor
  func test_nothingChosen_resolvesToABundledTV_thatLaysOutInLandscape() throws {
    ICubeBezels.configure()
    let suite = "GameplayBezelTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = UserDefaultsBezelSettings(defaults: defaults, prefix: ICubeBezels.settingsKeyPrefix)

    for isWii in [false, true] {
      let resolved = BezelChoice.resolve(gameID: nil, systemID: ICubeBezels.systemID(isWii: isWii), systemSuitsTV: true,
                                         preview: nil, settings: settings)
      XCTAssertTrue(resolved.resolution.isAutomatic)
      let bezel = try XCTUnwrap(resolved.bezel, "no TV for \(ICubeBezels.systemID(isWii: isWii))")
      let canvas = GameplayBezelTests.landscape
      let layout = try XCTUnwrap(TVBezelLayout(bezel: bezel, container: canvas, pictureAspect: CGSize(width: 4, height: 3)))
      XCTAssertEqual(layout.placement, .behindPicture, "a built-in TV's cabinet goes behind the picture")
      XCTAssertTrue(CGRect(origin: .zero, size: canvas).contains(layout.pictureFrame))
      XCTAssertTrue(layout.screenFrame.insetBy(dx: -0.5, dy: -0.5).contains(layout.pictureFrame))
      XCTAssertEqual(layout.pictureFrame.width / layout.pictureFrame.height, 4.0 / 3.0, accuracy: 0.01)
      XCTAssertNotNil(TVBezelPlainArtwork.image(for: bezel, maxPixel: canvas.width), "the TV's artwork could not be drawn")
    }
    // An explicit Off is no TV.
    settings.chosenBezel = ExternalDisplayBezelRules.noBezelID
    XCTAssertNil(BezelChoice.resolve(gameID: nil, systemID: ICubeBezels.gameCubeSystemID, systemSuitsTV: true,
                                     preview: nil, settings: settings).bezel)
    // The switcher's preview is read ahead of it.
    let preview = BezelPreview(choice: ExternalDisplayBezelRules.automaticBezelID, lightsRoom: false)
    XCTAssertNotNil(BezelChoice.resolve(gameID: nil, systemID: ICubeBezels.gameCubeSystemID, systemSuitsTV: true,
                                        preview: preview, settings: settings).bezel)
  }

  // MARK: - Keys

  func test_systemIDs_areTheSharedIdentifiers() {
    XCTAssertEqual(ICubeBezels.systemID(isWii: false), "com.provenance.gamecube")
    XCTAssertEqual(ICubeBezels.systemID(isWii: true), "com.provenance.wii")
  }

  func test_gameKey_prefersTheRunningGame() {
    XCTAssertEqual(ICubeBezels.gameKey(running: "GALE01", library: "GALP01"), "GALE01")
    XCTAssertEqual(ICubeBezels.gameKey(running: "", library: "GALP01"), "GALP01")
    XCTAssertNil(ICubeBezels.gameKey(running: "", library: ""))
  }

  // MARK: - Surface frame

  func test_aspectFit_centresThePicture() {
    let wide = ICubeBezels.aspectFit(aspect: 4.0 / 3.0, in: CGRect(x: 0, y: 0, width: 800, height: 300))
    assertRect(wide, CGRect(x: 200, y: 0, width: 400, height: 300))
    let tall = ICubeBezels.aspectFit(aspect: 2, in: CGRect(x: 10, y: 20, width: 300, height: 600))
    XCTAssertEqual(tall, CGRect(x: 10, y: 245, width: 300, height: 150))
    let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
    XCTAssertEqual(ICubeBezels.aspectFit(aspect: 0, in: bounds), bounds)
  }

  func test_surfaceFrame_isThePicture_whenNothingOlderIsOnIt() {
    let picture = CGRect(x: 100, y: 50, width: 400, height: 300)
    XCTAssertEqual(ICubeBezels.surfaceFrame(showing: picture, drawnAspect: nil), picture)
    XCTAssertEqual(ICubeBezels.surfaceFrame(showing: picture, drawnAspect: 4.0 / 3.0), picture)
    // Within the tolerance a rounding difference is the same shape.
    XCTAssertEqual(ICubeBezels.surfaceFrame(showing: picture, drawnAspect: 4.0 / 3.0 + 0.005), picture)
    XCTAssertEqual(ICubeBezels.surfaceFrame(showing: picture, drawnAspect: .nan), picture)
  }

  /// A paused frame drawn on a wide surface has bars beside the picture. The surface keeps that shape, sized so
  /// the picture inside it lands on the TV's screen.
  func test_surfaceFrame_keepsAWiderDrawnShape_aroundThePicture() {
    let picture = CGRect(x: 100, y: 50, width: 400, height: 300)
    let surface = ICubeBezels.surfaceFrame(showing: picture, drawnAspect: 2)
    XCTAssertEqual(surface, CGRect(x: 0, y: 50, width: 600, height: 300))
    // The core's aspect-fit of the picture inside that surface is the picture's frame.
    assertRect(ICubeBezels.aspectFit(aspect: 4.0 / 3.0, in: surface), picture)
  }

  func test_surfaceFrame_keepsATallerDrawnShape_aroundThePicture() {
    let picture = CGRect(x: 100, y: 50, width: 400, height: 300)
    let surface = ICubeBezels.surfaceFrame(showing: picture, drawnAspect: 1)
    XCTAssertEqual(surface, CGRect(x: 100, y: 0, width: 400, height: 400))
    assertRect(ICubeBezels.aspectFit(aspect: 4.0 / 3.0, in: surface), picture)
  }

  private func assertRect(_ rect: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
    let accuracy: CGFloat = 0.001
    XCTAssertEqual(rect.minX, expected.minX, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(rect.minY, expected.minY, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(rect.width, expected.width, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(rect.height, expected.height, accuracy: accuracy, file: file, line: line)
  }

  // MARK: - The strip's controller input

  func test_pad_firstPressesAreEdges() {
    var nav = BezelStripPadNav()
    XCTAssertEqual(nav.update(.init(right: true), at: 0), [.right])
    XCTAssertEqual(nav.update(.init(right: true), at: 0.1), [], "a hold repeats only after the delay")
    XCTAssertEqual(nav.update(.init(), at: 0.2), [])
    XCTAssertEqual(nav.update(.init(left: true), at: 0.3), [.left])
  }

  func test_pad_holdRepeatsAfterTheDelay() {
    var nav = BezelStripPadNav()
    _ = nav.update(.init(right: true), at: 0)
    XCTAssertEqual(nav.update(.init(right: true), at: 0.45), [.right])
    XCTAssertEqual(nav.update(.init(right: true), at: 0.46), [])
    XCTAssertEqual(nav.update(.init(right: true), at: 0.55), [.right])
  }

  func test_pad_buttonsMapToTheStripsActions() {
    var nav = BezelStripPadNav()
    XCTAssertEqual(nav.update(.init(a: true), at: 0), [.activate])
    XCTAssertEqual(nav.update(.init(b: true), at: 0.1), [.back])
    XCTAssertEqual(nav.update(.init(x: true), at: 0.2), [.toggleRoomLight])
    XCTAssertEqual(nav.update(.init(x: true), at: 0.3), [], "one toggle per press")
    XCTAssertEqual(nav.update(.init(y: true), at: 0.4), [.toggleThisGameOnly])
    XCTAssertEqual(nav.update(.init(leftShoulder: true), at: 0.5), [.previousGroup])
    XCTAssertEqual(nav.update(.init(rightShoulder: true), at: 0.6), [.nextGroup])
  }

  func test_pad_stickStepsOncePerPush() {
    var nav = BezelStripPadNav()
    XCTAssertEqual(nav.update(.init(stickX: 0.9), at: 0), [.right])
    XCTAssertEqual(nav.update(.init(stickX: 0.5), at: 0.05), [], "still engaged above the release threshold")
    XCTAssertEqual(nav.update(.init(stickX: 0.1), at: 0.1), [])
    XCTAssertEqual(nav.update(.init(stickX: -0.9), at: 0.15), [.left])
  }

  /// The A that chose "Bezels" in the pause menu is still down when the strip appears.
  func test_pad_resyncSwallowsWhatIsAlreadyHeld() {
    var nav = BezelStripPadNav()
    nav.resync(.init(right: true, a: true, x: true), at: 0)
    XCTAssertEqual(nav.update(.init(right: true, a: true, x: true), at: 1), [])
    XCTAssertEqual(nav.update(.init(), at: 1.1), [])
    XCTAssertEqual(nav.update(.init(a: true), at: 1.2), [.activate])
  }

  func test_pad_mergedInput_isAnyPad() {
    let merged = BezelStripPadNav.Input.merged([.init(left: true, stickX: 0.2), .init(stickX: -0.8, y: true)])
    XCTAssertEqual(merged, .init(left: true, stickX: -0.8, y: true))
    XCTAssertEqual(BezelStripPadNav.Input.merged([]), .init())
  }
}
