// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import XCTest
@testable import iCube

@MainActor
final class SkinMountTests: XCTestCase {
  private static let infoFileName = "info.json"
  /// A portrait-only GameCube skin: a 100x200 mapping with the game screen across its top half.
  private static let portraitOnlyInfo = """
  {"name":"Pocket","identifier":"pocket","gameTypeIdentifier":"public.aoshuang.game.ngc","representations":{
    "iphone":{"edgeToEdge":{"portrait":{"mappingSize":{"width":100,"height":200},
      "screens":[{"outputFrame":{"x":0,"y":0,"width":100,"height":100}}],"items":[]}}}}}
  """
  private static let screenlessInfo = """
  {"name":"Bare","identifier":"bare","gameTypeIdentifier":"public.aoshuang.game.ngc","representations":{
    "iphone":{"edgeToEdge":{"portrait":{"mappingSize":{"width":100,"height":200},"items":[]}}}}}
  """

  private var scratch: URL!
  private var library: SkinLibrary!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent("SkinMountTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    try install(Self.portraitOnlyInfo, folder: "pocket")
    try install(Self.screenlessInfo, folder: "bare")
    library = SkinLibrary(rootURL: scratch)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: scratch)
  }

  private func install(_ info: String, folder: String) throws {
    let directory = scratch.appendingPathComponent(folder, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try info.write(to: directory.appendingPathComponent(Self.infoFileName), atomically: true, encoding: .utf8)
  }

  private func skin(_ id: String) throws -> InstalledSkin {
    try XCTUnwrap(library.skins.first { $0.id == id })
  }

  // MARK: Overlay choice

  func testNoSelectionIsProgrammatic() {
    XCTAssertEqual(SkinMount.overlayChoice(padKind: .gameCube, orientation: .portrait, library: library, isPad: false), .programmatic)
  }

  func testSelectionForTheOtherOrientationOnlyIsProgrammatic() throws {
    library.select(try skin("pocket"), for: .gameCube, orientation: .landscape)
    XCTAssertEqual(SkinMount.overlayChoice(padKind: .gameCube, orientation: .portrait, library: library, isPad: false), .programmatic)
  }

  func testSelectedSkinIsChosenForItsOrientation() throws {
    let pocket = try skin("pocket")
    library.select(pocket, for: .gameCube, orientation: .portrait)
    XCTAssertEqual(SkinMount.overlayChoice(padKind: .gameCube, orientation: .portrait, library: library, isPad: false), .skin(pocket))
  }

  func testSkinWhoseFilesWereDeletedFallsBackAndClearsTheSelection() throws {
    let pocket = try skin("pocket")
    library.select(pocket, for: .gameCube, orientation: .portrait)
    try FileManager.default.removeItem(at: pocket.directory)
    XCTAssertEqual(SkinMount.overlayChoice(padKind: .gameCube, orientation: .portrait, library: library, isPad: false), .programmatic)
    XCTAssertNil(library.selectedSkin(for: .gameCube, orientation: .portrait), "the dead pick is forgotten")
  }

  func testSkinWithoutALayoutForTheOrientationFallsBackButKeepsTheSelection() throws {
    let pocket = try skin("pocket")
    library.select(pocket, for: .gameCube, orientation: .landscape)
    XCTAssertEqual(SkinMount.overlayChoice(padKind: .gameCube, orientation: .landscape, library: library, isPad: false), .programmatic)
    XCTAssertEqual(library.selectedSkin(for: .gameCube, orientation: .landscape), pocket)
  }

  // MARK: Hosted overlay

  func testHostedOverlayWhenTheFlagIsOnOrASkinIsChosen() throws {
    let pocket = try skin("pocket")
    XCTAssertTrue(SkinMount.usesHostedOverlay(flag: true, choice: .programmatic))
    XCTAssertTrue(SkinMount.usesHostedOverlay(flag: true, choice: .skin(pocket)))
    XCTAssertTrue(SkinMount.usesHostedOverlay(flag: false, choice: .skin(pocket)))
    XCTAssertFalse(SkinMount.usesHostedOverlay(flag: false, choice: .programmatic))
  }

  // MARK: Action notification

  func testSkinActionsTravelThroughTheNotification() {
    var received: [SkinAction] = []
    let token = NotificationCenter.default.addObserver(forName: SkinActionNotification.name, object: nil, queue: nil) { note in
      if let action = SkinActionNotification.action(in: note) { received.append(action) }
    }
    defer { NotificationCenter.default.removeObserver(token) }
    SkinActionNotification.post(.menu)
    SkinActionNotification.post(.quickSave)
    XCTAssertEqual(received, [.menu, .quickSave])
    XCTAssertNil(SkinActionNotification.action(in: Notification(name: SkinActionNotification.name)))
  }

  // MARK: Game picture

  func testGamePictureFrameIsTheSkinsScreenAreaOnTheCanvas() throws {
    // Scale 2 (200x400 canvas for a 100x200 mapping): the 100x100 screen becomes 200x200 at the top.
    let frame = SkinMount.gamePictureFrame(for: try skin("pocket"), canvas: CGSize(width: 200, height: 400), isPad: false)
    XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 200, height: 200))
  }

  func testGamePictureFrameFollowsTheLayoutsBottomAnchor() throws {
    // A taller canvas leaves the skin bottom-anchored, so the screen sits below the top edge.
    let frame = SkinMount.gamePictureFrame(for: try skin("pocket"), canvas: CGSize(width: 200, height: 500), isPad: false)
    XCTAssertEqual(frame, CGRect(x: 0, y: 100, width: 200, height: 200))
  }

  func testNoGamePictureFrameWithoutAScreenOrALayout() throws {
    XCTAssertNil(SkinMount.gamePictureFrame(for: try skin("bare"), canvas: CGSize(width: 200, height: 400), isPad: false))
    XCTAssertNil(SkinMount.gamePictureFrame(for: try skin("pocket"), canvas: CGSize(width: 400, height: 200), isPad: false),
                 "the portrait-only skin has no landscape layout")
  }

  func testAspectFitCentresInsideTheRect() {
    let rect = CGRect(x: 10, y: 20, width: 200, height: 100)
    XCTAssertEqual(SkinMount.aspectFit(aspect: 1, in: rect), CGRect(x: 60, y: 20, width: 100, height: 100), "pillarboxed")
    XCTAssertEqual(SkinMount.aspectFit(aspect: 4, in: rect), CGRect(x: 10, y: 45, width: 200, height: 50), "letterboxed")
    XCTAssertEqual(SkinMount.aspectFit(aspect: 2, in: rect), rect)
  }

  func testAspectFitWithoutAUsableAspectFillsTheRect() {
    let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
    XCTAssertEqual(SkinMount.aspectFit(aspect: 0, in: rect), rect)
  }
}
#endif
