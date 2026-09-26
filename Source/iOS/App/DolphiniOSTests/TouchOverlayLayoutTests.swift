// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import CoreGraphics
import XCTest

@testable import iCube

/// Phase 1 of the programmatic touch overlay: pure geometry, xib-derived defaults, the JSON layout
/// store, and the stick/d-pad write conventions. No UIKit, no core.
final class TouchOverlayLayoutTests: XCTestCase {
  // MARK: Engine

  func testClampCenterKeepsBoxInsideBounds() {
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
    let size = CGSize(width: 100, height: 50)
    XCTAssertEqual(TouchOverlayLayoutEngine.clampCenter(CGPoint(x: -20, y: -20), size: size, bounds: bounds),
                   CGPoint(x: 50, y: 25))
    XCTAssertEqual(TouchOverlayLayoutEngine.clampCenter(CGPoint(x: 900, y: 900), size: size, bounds: bounds),
                   CGPoint(x: 350, y: 275))
    XCTAssertEqual(TouchOverlayLayoutEngine.clampCenter(CGPoint(x: 200, y: 150), size: size, bounds: bounds),
                   CGPoint(x: 200, y: 150))
  }

  func testClampCenterCentresOversizedGroup() {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let p = TouchOverlayLayoutEngine.clampCenter(CGPoint(x: 5, y: 5), size: CGSize(width: 300, height: 20), bounds: bounds)
    XCTAssertEqual(p.x, 50)
    XCTAssertEqual(p.y, 10)
  }

  func testResolveIsFreePlacementClampedOnly() {
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
    let size = CGSize(width: 40, height: 40)
    XCTAssertEqual(TouchOverlayLayoutEngine.resolve(proposed: CGPoint(x: 123.4, y: 56.7), size: size, bounds: bounds),
                   CGPoint(x: 123.4, y: 56.7))
    XCTAssertEqual(TouchOverlayLayoutEngine.resolve(proposed: CGPoint(x: 1000, y: 1000), size: size, bounds: bounds),
                   CGPoint(x: 380, y: 280))
  }

  func testIsValidRejectsOverlapAndOffscreen() {
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
    let other = CGRect(x: 100, y: 100, width: 50, height: 50)
    XCTAssertFalse(TouchOverlayLayoutEngine.isValid(center: CGPoint(x: 152, y: 125), size: CGSize(width: 40, height: 40), others: [other], bounds: bounds))
    XCTAssertTrue(TouchOverlayLayoutEngine.isValid(center: CGPoint(x: 300, y: 125), size: CGSize(width: 40, height: 40), others: [other], bounds: bounds))
    XCTAssertFalse(TouchOverlayLayoutEngine.isValid(center: CGPoint(x: 10, y: 10), size: CGSize(width: 40, height: 40), others: [], bounds: bounds))
  }

  func testNormalizeRoundTrips() {
    let bounds = CGRect(x: 10, y: 20, width: 200, height: 100)
    let p = CGPoint(x: 60, y: 45)
    let n = TouchOverlayLayoutEngine.normalize(p, in: bounds)
    XCTAssertEqual(n.x, 0.25, accuracy: 1e-9)
    XCTAssertEqual(n.y, 0.25, accuracy: 1e-9)
    let back = TouchOverlayLayoutEngine.denormalize(n, in: bounds)
    XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
    XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
  }

  // MARK: Placement anchors

  func testAnchorsHangFromTheRightEdges() {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    let size = CGSize(width: 100, height: 40)
    XCTAssertEqual(TouchOverlayPlacement(.bottomLeading, inset: CGPoint(x: 64, y: 30), size: size).center(in: bounds), CGPoint(x: 64, y: 570))
    XCTAssertEqual(TouchOverlayPlacement(.bottomTrailing, inset: CGPoint(x: 64, y: 30), size: size).center(in: bounds), CGPoint(x: 736, y: 570))
    XCTAssertEqual(TouchOverlayPlacement(.bottomCenter, inset: CGPoint(x: 0, y: 30), size: size).center(in: bounds), CGPoint(x: 400, y: 570))
    let fill = TouchOverlayPlacement(.fill)
    XCTAssertEqual(fill.box(in: bounds), bounds)
    // Phase 3 (task item 1): `.fillInset` is `.fill` minus a uniform margin, resizable/movable
    // like any other group (unlike `.fill`, whose size is fixed to `bounds`).
    let fillInset = TouchOverlayPlacement(.fillInset, margin: 20)
    XCTAssertEqual(fillInset.center(in: bounds), CGPoint(x: 400, y: 300))
    XCTAssertEqual(fillInset.box(in: bounds), bounds.insetBy(dx: 20, dy: 20))
  }

  // MARK: Defaults reproduce the xib frames at their design size

  private func designBounds(_ kind: TouchOverlayPadKind) -> CGRect {
    CGRect(origin: .zero, size: TouchOverlayDefaults.designSize(for: kind))
  }

  private func box(_ group: TouchOverlayGroup, _ kind: TouchOverlayPadKind) -> CGRect {
    let layout = TouchOverlayDefaults.layout(for: group, kind: kind, orientation: .portrait)
    XCTAssertNotNil(layout, "\(kind) has no \(group)")
    return layout!.placement.box(in: designBounds(kind))
  }

  /// A control's absolute frame at the design size = group box origin + control frame.
  private func controlFrame(_ id: String, _ group: TouchOverlayGroup, _ kind: TouchOverlayPadKind) -> CGRect {
    let layout = TouchOverlayDefaults.layout(for: group, kind: kind, orientation: .portrait)!
    let b = layout.placement.box(in: designBounds(kind))
    let c = layout.controls.first { $0.id == id }!
    return c.frame.offsetBy(dx: b.minX, dy: b.minY)
  }

  func testGameCubeDefaultsMatchXib() {
    XCTAssertEqual(box(.gcMainStick, .gameCube), CGRect(x: 0, y: 768, width: 128, height: 128))
    XCTAssertEqual(box(.gcDpad, .gameCube), CGRect(x: 128, y: 896, width: 128, height: 128))
    XCTAssertEqual(box(.gcCStick, .gameCube), CGRect(x: 548, y: 896, width: 128, height: 128))
    XCTAssertEqual(controlFrame("gc.a", .gcFaceButtons, .gameCube), CGRect(x: 676, y: 866, width: 46, height: 30))
    XCTAssertEqual(controlFrame("gc.x", .gcFaceButtons, .gameCube), CGRect(x: 722, y: 851, width: 46, height: 30))
    XCTAssertEqual(controlFrame("gc.start", .gcLeftShoulder, .gameCube), CGRect(x: 86, y: 821, width: 46, height: 30))
    XCTAssertEqual(controlFrame("gc.r", .gcRightShoulder, .gameCube), CGRect(x: 722, y: 821, width: 46, height: 30))
  }

  func testWiiRemoteDefaultsMatchXib() {
    XCTAssertEqual(box(.wiiDpad, .wiiRemote), CGRect(x: 0, y: 401, width: 128, height: 128))
    XCTAssertEqual(box(.nunchukStick, .wiiRemote), CGRect(x: 0, y: 539, width: 128, height: 128))
    XCTAssertEqual(controlFrame("wii.a", .wiiAB, .wiiRemote), CGRect(x: 309, y: 597, width: 46, height: 30))
    XCTAssertEqual(controlFrame("wii.b", .wiiAB, .wiiRemote), CGRect(x: 309, y: 527, width: 46, height: 30))
    XCTAssertEqual(controlFrame("wii.two", .wiiOneTwo, .wiiRemote), CGRect(x: 248, y: 622, width: 46, height: 30))
    XCTAssertEqual(controlFrame("wii.home", .wiiMinusPlusHome, .wiiRemote), CGRect(x: 187, y: 477, width: 46, height: 30))
    XCTAssertEqual(controlFrame("wii.minus", .wiiMinusPlusHome, .wiiRemote), CGRect(x: 248, y: 522, width: 46, height: 30))
    XCTAssertEqual(box(.nunchukZ, .wiiRemote), CGRect(x: 309, y: 477, width: 46, height: 30))
    // Phase 3 (task item 1): the IR pad's default rect is the whole pad minus a safe margin, not
    // the phase-2 placeholder's literal full bounds, so it's reachable and resizable like any
    // other group.
    XCTAssertEqual(box(.wiiIRPad, .wiiRemote),
                   designBounds(.wiiRemote).insetBy(dx: TouchOverlayDefaults.irPadMargin, dy: TouchOverlayDefaults.irPadMargin))
  }

  func testSidewaysDefaultsMatchXib() {
    XCTAssertEqual(box(.sidewaysB, .wiiRemoteSideways), CGRect(x: 25.5, y: 779, width: 77, height: 77))
    XCTAssertEqual(controlFrame("wii.a", .sidewaysFaceCluster, .wiiRemoteSideways), CGRect(x: 705, y: 878, width: 43, height: 43))
    XCTAssertEqual(controlFrame("wii.plus", .sidewaysFaceCluster, .wiiRemoteSideways), CGRect(x: 630.5, y: 886.5, width: 26, height: 26))
    XCTAssertEqual(box(.sidewaysHome, .wiiRemoteSideways), CGRect(x: 368, y: 992, width: 32, height: 32))
  }

  func testClassicDefaultsMatchXib() {
    XCTAssertEqual(controlFrame("classic.zl", .classicLeftShoulder, .wiiClassic), CGRect(x: 16, y: 302, width: 77, height: 77))
    XCTAssertEqual(controlFrame("classic.r", .classicRightShoulder, .wiiClassic), CGRect(x: 282, y: 352, width: 77, height: 77))
    XCTAssertEqual(box(.classicDpad, .wiiClassic), CGRect(x: 22.5, y: 435, width: 115, height: 115))
    XCTAssertEqual(controlFrame("classic.y", .classicFaceButtons, .wiiClassic), CGRect(x: 228, y: 471, width: 43, height: 43))
    XCTAssertEqual(controlFrame("classic.b", .classicFaceButtons, .wiiClassic), CGRect(x: 269.5, y: 508, width: 43, height: 43))
    XCTAssertEqual(box(.classicRightStick, .wiiClassic), CGRect(x: 227, y: 543, width: 128, height: 128))
    XCTAssertEqual(controlFrame("classic.home", .classicMinusPlusHome, .wiiClassic), CGRect(x: 171.5, y: 636, width: 32, height: 32))
  }

  func testEveryPadKindHasUniqueGroupsAndControlIds() {
    for kind in TouchOverlayPadKind.allCases {
      for orientation in TouchOverlayOrientation.allCases {
        let layouts = TouchOverlayDefaults.layout(for: kind, orientation: orientation)
        XCTAssertFalse(layouts.isEmpty, "\(kind) \(orientation)")
        let groups = layouts.map(\.group)
        XCTAssertEqual(Set(groups).count, groups.count, "\(kind): duplicate group")
        let ids = layouts.flatMap { $0.controls.map(\.id) }
        XCTAssertEqual(Set(ids).count, ids.count, "\(kind): duplicate control id")
        // The IR surface's control has a `.zero` placeholder frame (it isn't a positioned button —
        // §2.1) and its group's `size` field is likewise unset for a `.fillInset` anchor (the real
        // size is computed dynamically from bounds), so skip it by CONTROL KIND, not anchor.
        for layout in layouts where !layout.controls.contains(where: { if case .irSurface = $0.kind { return true }; return false }) {
          for control in layout.controls {
            XCTAssertTrue(CGRect(origin: .zero, size: layout.size).insetBy(dx: -0.5, dy: -0.5).contains(control.frame),
                          "\(kind) \(layout.group) \(control.id) leaves its group box")
          }
        }
      }
    }
  }

  func testWiiPadKindSelectionMirrorsMakeWiiPadView() {
    XCTAssertEqual(TouchOverlayPadKind.wii(classicActive: true, sideways: true), .wiiClassic)
    XCTAssertEqual(TouchOverlayPadKind.wii(classicActive: false, sideways: true), .wiiRemoteSideways)
    XCTAssertEqual(TouchOverlayPadKind.wii(classicActive: false, sideways: false), .wiiRemote)
  }

  // MARK: Store

  private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("touch-overlay-tests-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent(TouchOverlayLayoutStore.fileName)
  }

  @MainActor
  func testStoreRoundTripsThroughFileAndResets() throws {
    let url = temporaryFile()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let store = TouchOverlayLayoutStore(fileURL: url)
    XCTAssertNil(store.normalizedCenter(for: .gcDpad, padKind: .gameCube, orientation: .portrait))
    XCTAssertFalse(store.hasCustomLayout(padKind: .gameCube, orientation: .portrait))

    store.setNormalizedCenter(CGPoint(x: 0.25, y: 1.7), for: .gcDpad, padKind: .gameCube, orientation: .portrait)
    XCTAssertEqual(store.revision, 1)
    XCTAssertEqual(store.normalizedCenter(for: .gcDpad, padKind: .gameCube, orientation: .portrait), CGPoint(x: 0.25, y: 1))
    XCTAssertNil(store.normalizedCenter(for: .gcDpad, padKind: .gameCube, orientation: .landscape), "orientations are independent")

    let reloaded = TouchOverlayLayoutStore(fileURL: url)
    XCTAssertEqual(reloaded.normalizedCenter(for: .gcDpad, padKind: .gameCube, orientation: .portrait), CGPoint(x: 0.25, y: 1))
    XCTAssertTrue(reloaded.hasCustomLayout(padKind: .gameCube, orientation: .portrait))

    reloaded.reset(padKind: .gameCube)
    XCTAssertNil(reloaded.normalizedCenter(for: .gcDpad, padKind: .gameCube, orientation: .portrait))
    XCTAssertNil(TouchOverlayLayoutStore(fileURL: url).normalizedCenter(for: .gcDpad, padKind: .gameCube, orientation: .portrait))
  }

  @MainActor
  func testResolvedBoxFallsBackToDefaultAndClampsStoredCenters() {
    let store = TouchOverlayLayoutStore(fileURL: nil)
    let bounds = CGRect(x: 0, y: 0, width: 768, height: 1024)
    let dpad = TouchOverlayDefaults.layout(for: .gcDpad, kind: .gameCube, orientation: .portrait)!
    XCTAssertEqual(store.resolvedBox(for: dpad, padKind: .gameCube, orientation: .portrait, in: bounds),
                   CGRect(x: 128, y: 896, width: 128, height: 128))

    store.setCenter(CGPoint(x: 760, y: 10), in: bounds, for: .gcDpad, padKind: .gameCube, orientation: .portrait)
    let moved = store.resolvedBox(for: dpad, padKind: .gameCube, orientation: .portrait, in: bounds)
    XCTAssertEqual(moved, CGRect(x: 640, y: 0, width: 128, height: 128), "stored centre is re-clamped on-screen")

    let smaller = CGRect(x: 0, y: 0, width: 384, height: 512)
    let rescaled = store.resolvedBox(for: dpad, padKind: .gameCube, orientation: .portrait, in: smaller)
    XCTAssertEqual(rescaled.maxX, 384, "normalized centre follows the new bounds and stays inside")
  }

  // MARK: Input conventions (§6.4)

  func testStickAxesClampToTravelCircle() {
    let center = CGPoint(x: 100, y: 100)
    let inside = TouchOverlayInput.stickAxes(touch: CGPoint(x: 110, y: 90), center: center, maxDistance: 40)
    XCTAssertEqual(inside.x, 0.25, accuracy: 1e-9)
    XCTAssertEqual(inside.y, -0.25, accuracy: 1e-9)
    let far = TouchOverlayInput.stickAxes(touch: CGPoint(x: 100, y: 300), center: center, maxDistance: 40)
    XCTAssertEqual(far.x, 0, accuracy: 1e-9)
    XCTAssertEqual(far.y, 1, accuracy: 1e-9)
    let diagonal = TouchOverlayInput.stickAxes(touch: CGPoint(x: 400, y: 400), center: center, maxDistance: 40)
    XCTAssertEqual(hypot(diagonal.x, diagonal.y), 1, accuracy: 1e-9)
  }

  func testStickWritesKeepTCJoystickConvention() {
    // Up: min(y, 0) and min(y, 1) are BOTH y when y is negative, so the negative value lands on
    // the Up and the Down id alike; only a positive y is one-sided. Base 10 -> ids 11...14.
    let up = TouchOverlayInput.stickWrites(x: 0, y: -0.5, baseId: 10)
    XCTAssertEqual(up.map(\.id), [11, 12, 13, 14])
    XCTAssertEqual(up.map(\.value), [-0.5, -0.5, 0, 0])
    // Down-right: 0 to Up, positive to Down; 0 to Left, positive to Right.
    let downRight = TouchOverlayInput.stickWrites(x: 0.75, y: 1, baseId: 202)
    XCTAssertEqual(downRight.map(\.id), [203, 204, 205, 206])
    XCTAssertEqual(downRight.map(\.value), [0, 1, 0, 0.75])
    // Left: the negative value reaches both horizontal ids for the same reason.
    XCTAssertEqual(TouchOverlayInput.stickWrites(x: -1, y: 0, baseId: 15).map(\.value), [0, 0, -1, -1])
  }

  func testDpadWritesUseUpDownLeftRightOrder() {
    let writes = TouchOverlayInput.dpadWrites(up: true, down: false, left: false, right: true, baseId: 107)
    XCTAssertEqual(writes.map(\.id), [107, 108, 109, 110])
    XCTAssertEqual(writes.map(\.pressed), [true, false, false, true])
  }

  // MARK: Phase 2 — size scale (§2.4)

  @MainActor
  func testSizeScaleDefaultsToOneAndPersistsA2ElementEntry() {
    let store = TouchOverlayLayoutStore(fileURL: nil)
    XCTAssertEqual(store.sizeScale(for: .gcDpad, padKind: .gameCube, orientation: .portrait), 1.0)
    // A plain 2-element move (phase 1 shape) must keep reading scale 1.0.
    store.setNormalizedCenter(CGPoint(x: 0.3, y: 0.4), for: .gcDpad, padKind: .gameCube, orientation: .portrait)
    XCTAssertEqual(store.sizeScale(for: .gcDpad, padKind: .gameCube, orientation: .portrait), 1.0)
  }

  @MainActor
  func testSetSizeScaleRoundTripsAndPreservesCenter() throws {
    let url = temporaryFile()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let store = TouchOverlayLayoutStore(fileURL: url)
    store.setNormalizedCenter(CGPoint(x: 0.2, y: 0.6), for: .gcCStick, padKind: .gameCube, orientation: .portrait)
    store.setSizeScale(1.5, for: .gcCStick, padKind: .gameCube, orientation: .portrait, defaultCenter: CGPoint(x: 0.9, y: 0.9))
    XCTAssertEqual(store.sizeScale(for: .gcCStick, padKind: .gameCube, orientation: .portrait), 1.5)
    // The center set beforehand must survive the resize write.
    XCTAssertEqual(store.normalizedCenter(for: .gcCStick, padKind: .gameCube, orientation: .portrait), CGPoint(x: 0.2, y: 0.6))

    let reloaded = TouchOverlayLayoutStore(fileURL: url)
    XCTAssertEqual(reloaded.sizeScale(for: .gcCStick, padKind: .gameCube, orientation: .portrait), 1.5)
    XCTAssertEqual(reloaded.normalizedCenter(for: .gcCStick, padKind: .gameCube, orientation: .portrait), CGPoint(x: 0.2, y: 0.6))
  }

  @MainActor
  func testSetSizeScaleUsesDefaultCenterWhenGroupNeverMoved() {
    let store = TouchOverlayLayoutStore(fileURL: nil)
    store.setSizeScale(0.75, for: .gcDpad, padKind: .gameCube, orientation: .portrait, defaultCenter: CGPoint(x: 0.5, y: 0.5))
    XCTAssertEqual(store.normalizedCenter(for: .gcDpad, padKind: .gameCube, orientation: .portrait), CGPoint(x: 0.5, y: 0.5))
    XCTAssertEqual(store.sizeScale(for: .gcDpad, padKind: .gameCube, orientation: .portrait), 0.75)
  }

  @MainActor
  func testSetSizeScaleClampsToScaleRange() {
    let store = TouchOverlayLayoutStore(fileURL: nil)
    store.setSizeScale(10, for: .gcDpad, padKind: .gameCube, orientation: .portrait, defaultCenter: .zero)
    XCTAssertEqual(store.sizeScale(for: .gcDpad, padKind: .gameCube, orientation: .portrait), TouchOverlayLayoutStore.scaleRange.upperBound)
    store.setSizeScale(0.01, for: .gcCStick, padKind: .gameCube, orientation: .portrait, defaultCenter: .zero)
    XCTAssertEqual(store.sizeScale(for: .gcCStick, padKind: .gameCube, orientation: .portrait), TouchOverlayLayoutStore.scaleRange.lowerBound)
  }

  @MainActor
  func testResolvedBoxScalesSizeBeforeClamping() {
    let store = TouchOverlayLayoutStore(fileURL: nil)
    let bounds = CGRect(x: 0, y: 0, width: 768, height: 1024)
    let dpad = TouchOverlayDefaults.layout(for: .gcDpad, kind: .gameCube, orientation: .portrait)!
    store.setSizeScale(2.0, for: .gcDpad, padKind: .gameCube, orientation: .portrait,
                       defaultCenter: TouchOverlayLayoutEngine.normalize(dpad.placement.center(in: bounds), in: bounds))
    let box = store.resolvedBox(for: dpad, padKind: .gameCube, orientation: .portrait, in: bounds)
    XCTAssertEqual(box.width, dpad.size.width * 2, accuracy: 1e-9)
    XCTAssertEqual(box.height, dpad.size.height * 2, accuracy: 1e-9)
  }

  // MARK: Hit tester (§3)

  func testUnionMatchesEachTouchToItsOwnRegion() {
    let regions = [
      TouchOverlayHitTester.Region(id: "a", frame: CGRect(x: 0, y: 0, width: 10, height: 10)),
      TouchOverlayHitTester.Region(id: "b", frame: CGRect(x: 20, y: 0, width: 10, height: 10)),
    ]
    let hit = TouchOverlayHitTester.union(touches: [CGPoint(x: 5, y: 5), CGPoint(x: 25, y: 5)], regions: regions)
    XCTAssertEqual(hit, ["a", "b"])
  }

  func testUnionIgnoresTouchesOutsideEveryRegion() {
    let regions = [TouchOverlayHitTester.Region(id: "a", frame: CGRect(x: 0, y: 0, width: 10, height: 10))]
    XCTAssertEqual(TouchOverlayHitTester.union(touches: [CGPoint(x: 50, y: 50)], regions: regions), [])
  }

  func testDeltaReportsOnlyPressedAndReleasedTransitions() {
    let (pressed, released) = TouchOverlayHitTester.delta(previous: ["a", "b"], now: ["b", "c"])
    XCTAssertEqual(pressed, ["c"])
    XCTAssertEqual(released, ["a"])
  }

  func testDeltaIsEmptyWhenNothingChanges() {
    let (pressed, released) = TouchOverlayHitTester.delta(previous: ["a"], now: ["a"])
    XCTAssertTrue(pressed.isEmpty)
    XCTAssertTrue(released.isEmpty)
  }

  // MARK: D-pad angle bucketing (§3 / VCODPad.directions parity, NOT TCDirectionalPad's grid)

  func testDpadDirectionsDeadzoneAtCenter() {
    let size = CGSize(width: 128, height: 128)
    XCTAssertEqual(TouchOverlayHitTester.dpadDirections(at: CGPoint(x: 64, y: 64), in: size, previous: []), [])
  }

  func testDpadDirectionsCardinals() {
    let size = CGSize(width: 128, height: 128)
    // Straight up from center (negative y, UIKit coordinates).
    XCTAssertEqual(TouchOverlayHitTester.dpadDirections(at: CGPoint(x: 64, y: 10), in: size, previous: []), [.up])
    XCTAssertEqual(TouchOverlayHitTester.dpadDirections(at: CGPoint(x: 64, y: 118), in: size, previous: []), [.down])
    XCTAssertEqual(TouchOverlayHitTester.dpadDirections(at: CGPoint(x: 10, y: 64), in: size, previous: []), [.left])
    XCTAssertEqual(TouchOverlayHitTester.dpadDirections(at: CGPoint(x: 118, y: 64), in: size, previous: []), [.right])
  }

  func testDpadDirectionsDiagonal() {
    let size = CGSize(width: 128, height: 128)
    // Down-right octant.
    let dirs = TouchOverlayHitTester.dpadDirections(at: CGPoint(x: 110, y: 110), in: size, previous: [])
    XCTAssertEqual(dirs, [.down, .right])
  }

  func testDpadDirectionsHysteresisStaysStickyNearTheSeam() {
    let size = CGSize(width: 128, height: 128)
    // 20 degrees is just PAST the [.down, .right] sector's plain lower bound (22.5) on the
    // [.right]-only side — without hysteresis this reads as [.right] alone. Coming from
    // [.down, .right] as `previous`, it's still within the +8 degree sticky margin, so it should
    // stay put instead of dropping the diagonal.
    let radians = 20.0 * Double.pi / 180
    let point = CGPoint(x: 64 + 50 * cos(radians), y: 64 + 50 * sin(radians))
    XCTAssertEqual(TouchOverlayHitTester.dpadDirections(at: point, in: size, previous: []), [.right],
                   "sanity check: without a sticky previous, 20 degrees alone is plain [.right]")
    let dirs = TouchOverlayHitTester.dpadDirections(at: point, in: size, previous: [.down, .right])
    XCTAssertEqual(dirs, [.down, .right])
  }

  // MARK: Phase 3 — Wii IR pure geometry (task item 1 / design §6.4-6.6)

  private func assertRectEqual(_ a: CGRect, _ b: CGRect, accuracy: CGFloat = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.minX, b.minX, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.minY, b.minY, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.width, b.width, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.height, b.height, accuracy: accuracy, file: file, line: line)
  }

  func testLetterboxedGameRectNarrowsToAspectRatio() {
    // A rect already matching the surface aspect ratio passes through unchanged.
    let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
    assertRectEqual(TouchOverlayIRGeometry.letterboxedGameRect(in: rect, aspectRatio: rect.width / rect.height), rect)

    let wideSurface = CGRect(x: 0, y: 0, width: 400, height: 300)
    let narrowed = TouchOverlayIRGeometry.letterboxedGameRect(in: wideSurface, aspectRatio: 1.0)
    // 1:1 inside a 4:3 (400x300) surface: height stays 300, width shrinks to 300, centered.
    assertRectEqual(narrowed, CGRect(x: 50, y: 0, width: 300, height: 300))

    let tallSurface = CGRect(x: 0, y: 0, width: 300, height: 400)
    let letterboxedTop = TouchOverlayIRGeometry.letterboxedGameRect(in: tallSurface, aspectRatio: 1.0)
    // 1:1 inside a 3:4 (300x400) surface: width stays 300, height shrinks to 300, centered
    // vertically (bars on top/bottom).
    assertRectEqual(letterboxedTop, CGRect(x: 0, y: 50, width: 300, height: 300))
  }

  func testLetterboxedGameRectFallsBackWhenAspectRatioIsInvalid() {
    let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
    XCTAssertEqual(TouchOverlayIRGeometry.letterboxedGameRect(in: rect, aspectRatio: 0), rect)
    XCTAssertEqual(TouchOverlayIRGeometry.letterboxedGameRect(in: rect, aspectRatio: .nan), rect)
    XCTAssertEqual(TouchOverlayIRGeometry.letterboxedGameRect(in: .zero, aspectRatio: 4.0 / 3.0), .zero)
  }

  func testFollowMapsAbsolutePositionToNormalizedCoordsClamped() {
    let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
    XCTAssertEqual(TouchOverlayIRGeometry.follow(point: CGPoint(x: 100, y: 50), in: rect).x, 0, accuracy: 1e-9)
    XCTAssertEqual(TouchOverlayIRGeometry.follow(point: CGPoint(x: 100, y: 50), in: rect).y, 0, accuracy: 1e-9)
    let corner = TouchOverlayIRGeometry.follow(point: CGPoint(x: 200, y: 100), in: rect)
    XCTAssertEqual(corner.x, 1, accuracy: 1e-9)
    XCTAssertEqual(corner.y, 1, accuracy: 1e-9)
    // Past the rect entirely: still clamps to [-1, 1], doesn't overshoot.
    let beyond = TouchOverlayIRGeometry.follow(point: CGPoint(x: 1000, y: -1000), in: rect)
    XCTAssertEqual(beyond.x, 1, accuracy: 1e-9)
    XCTAssertEqual(beyond.y, -1, accuracy: 1e-9)
  }

  func testDragAccumulatesFromPreviousPositionAndClamps() {
    let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
    // Half the rect's half-width to the right, from a start at the origin, with no prior offset.
    let first = TouchOverlayIRGeometry.drag(start: CGPoint(x: 0, y: 0), current: CGPoint(x: 50, y: 0),
                                            oldX: 0, oldY: 0, in: rect)
    XCTAssertEqual(first.x, 0.5, accuracy: 1e-9)
    XCTAssertEqual(first.y, 0, accuracy: 1e-9)
    // A second drag continues from the persisted (oldX, oldY), not from zero.
    let second = TouchOverlayIRGeometry.drag(start: CGPoint(x: 0, y: 0), current: CGPoint(x: 50, y: 0),
                                             oldX: first.x, oldY: first.y, in: rect)
    XCTAssertEqual(second.x, 1.0, accuracy: 1e-9, "0.5 + 0.5 clamps at the edge, not overshoots")
    // A large negative delta clamps at -1 rather than wrapping or going out of range.
    let clamped = TouchOverlayIRGeometry.drag(start: CGPoint(x: 0, y: 0), current: CGPoint(x: -1000, y: 0),
                                              oldX: 0, oldY: 0, in: rect)
    XCTAssertEqual(clamped.x, -1, accuracy: 1e-9)
  }

  func testTouchStartAllowedExcludesPointsInsideOtherGroups() {
    let otherFrames = [CGRect(x: 0, y: 0, width: 50, height: 50), CGRect(x: 100, y: 100, width: 50, height: 50)]
    XCTAssertFalse(TouchOverlayIRGeometry.touchStartAllowed(at: CGPoint(x: 10, y: 10), excluding: otherFrames),
                   "inside the first excluded frame")
    XCTAssertFalse(TouchOverlayIRGeometry.touchStartAllowed(at: CGPoint(x: 120, y: 120), excluding: otherFrames),
                   "inside the second excluded frame")
    XCTAssertTrue(TouchOverlayIRGeometry.touchStartAllowed(at: CGPoint(x: 75, y: 75), excluding: otherFrames),
                  "empty overlay space between the two excluded frames")
    XCTAssertTrue(TouchOverlayIRGeometry.touchStartAllowed(at: CGPoint(x: 10, y: 10), excluding: []),
                 "nothing to exclude")
  }

  // MARK: Phase 3 — force-sensitive analog trigger pressure (task item 2)

  func testPressureValueFallsBackToOneWithoutForceSupport() {
    XCTAssertEqual(TouchOverlayInput.pressureValue(force: 0, maximumPossibleForce: 0), 1.0)
    XCTAssertEqual(TouchOverlayInput.pressureValue(force: 0, maximumPossibleForce: 4.0), 1.0,
                  "no real sample yet (force == 0) reads as the initial full press, not near-zero")
  }

  func testPressureValueNormalizesAndClampsToOne() {
    XCTAssertEqual(TouchOverlayInput.pressureValue(force: 2.0, maximumPossibleForce: 4.0), 0.5, accuracy: 1e-6)
    XCTAssertEqual(TouchOverlayInput.pressureValue(force: 8.0, maximumPossibleForce: 4.0), 1.0,
                  "over-max force clamps at 1.0 rather than exceeding it")
  }

  // MARK: Phase 3 — overlay opacity (task item 1, C9)

  func testResolvedOpacityIsFullWhileEditingRegardlessOfConfiguredValue() {
    XCTAssertEqual(TouchOverlayInput.resolvedOpacity(isEditing: true, configuredOpacity: 0.1), 1.0)
    XCTAssertEqual(TouchOverlayInput.resolvedOpacity(isEditing: true, configuredOpacity: 1.0), 1.0)
  }

  func testResolvedOpacityFloorsAtPointTwoWhenNotEditing() {
    XCTAssertEqual(TouchOverlayInput.resolvedOpacity(isEditing: false, configuredOpacity: 0.0), 0.2)
    XCTAssertEqual(TouchOverlayInput.resolvedOpacity(isEditing: false, configuredOpacity: 0.05), 0.2)
  }

  func testResolvedOpacityPassesThroughConfiguredValueAboveTheFloor() {
    XCTAssertEqual(TouchOverlayInput.resolvedOpacity(isEditing: false, configuredOpacity: 0.6), 0.6, accuracy: 1e-6)
  }

  // MARK: Phase 3 — IR pointer sensitivity gain (task item 1, C9)

  func testClampDragGainFoldsInvalidValuesToNeutral() {
    XCTAssertEqual(TouchOverlayIRGeometry.clampDragGain(0), 1.0)
    XCTAssertEqual(TouchOverlayIRGeometry.clampDragGain(-1), 1.0)
    XCTAssertEqual(TouchOverlayIRGeometry.clampDragGain(.nan), 1.0)
    // `.infinity.isFinite` is false, so this hits the SAME "invalid -> neutral" branch as the
    // other three, not the finite `.upperBound` clamp `testClampDragGainClampsToRange` covers.
    XCTAssertEqual(TouchOverlayIRGeometry.clampDragGain(.infinity), 1.0)
  }

  func testClampDragGainClampsToRange() {
    XCTAssertEqual(TouchOverlayIRGeometry.clampDragGain(100), TouchOverlayIRGeometry.dragGainRange.upperBound)
    XCTAssertEqual(TouchOverlayIRGeometry.clampDragGain(0.001), TouchOverlayIRGeometry.dragGainRange.lowerBound)
    XCTAssertEqual(TouchOverlayIRGeometry.clampDragGain(1.5), 1.5, accuracy: 1e-9)
  }

  func testDragGainScalesTheDeltaNotTheAccumulatedOutput() {
    let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
    // With gain 1.0 (the default / every existing caller), behavior is byte-for-bit unchanged
    // from `testDragAccumulatesFromPreviousPositionAndClamps` above.
    let unity = TouchOverlayIRGeometry.drag(start: .zero, current: CGPoint(x: 50, y: 0), oldX: 0, oldY: 0, in: rect)
    XCTAssertEqual(unity.x, 0.5, accuracy: 1e-9)

    // Gain 2.0 doubles a SINGLE delta...
    let doubled = TouchOverlayIRGeometry.drag(start: .zero, current: CGPoint(x: 50, y: 0), oldX: 0, oldY: 0, in: rect, gain: 2.0)
    XCTAssertEqual(doubled.x, 1.0, accuracy: 1e-9)

    // ...and, critically, a SECOND successive drag at the same gain adds another equally-scaled
    // delta on top of the first drag's OUTPUT, rather than re-scaling that output — i.e. linear
    // accumulation (0.25 + 0.5 = 0.75 at gain 2, from two 25%-of-half-width deltas), not
    // geometric compounding (which would read 0.25, then 2 * (2*0.25) = 1.0 after only two drags
    // of the smaller size). Uses a smaller delta than `unity`/`doubled` above specifically so the
    // sum doesn't hit the [-1, 1] clamp before the assertion can distinguish the two shapes.
    let firstOfTwo = TouchOverlayIRGeometry.drag(start: .zero, current: CGPoint(x: 25, y: 0), oldX: 0, oldY: 0, in: rect, gain: 2.0)
    XCTAssertEqual(firstOfTwo.x, 0.5, accuracy: 1e-9)
    let secondOfTwo = TouchOverlayIRGeometry.drag(start: .zero, current: CGPoint(x: 25, y: 0), oldX: firstOfTwo.x, oldY: firstOfTwo.y, in: rect, gain: 2.0)
    XCTAssertEqual(secondOfTwo.x, 1.0, accuracy: 1e-9, "linear: 0.5 + (2 * 0.25) = 1.0, not 2 * 0.5 = 1.0-that-would-also-pass by coincidence")

    // Explicitly distinguish from the compounding shape using deltas that would diverge before
    // hitting the clamp: at gain 3, delta 10/100 (half-width) = 0.1 unscaled, 0.3 scaled.
    let smallRect = CGRect(x: 0, y: 0, width: 2000, height: 100)
    let firstSmall = TouchOverlayIRGeometry.drag(start: .zero, current: CGPoint(x: 100, y: 0), oldX: 0, oldY: 0, in: smallRect, gain: 3.0)
    XCTAssertEqual(firstSmall.x, 0.3, accuracy: 1e-9)
    let secondSmall = TouchOverlayIRGeometry.drag(start: .zero, current: CGPoint(x: 100, y: 0), oldX: firstSmall.x, oldY: firstSmall.y, in: smallRect, gain: 3.0)
    // Linear: 0.3 + 0.3 = 0.6. Compounding (scaling the sum) would instead give 3 * (0.1 + 0.1) = 0.6
    // too by coincidence at this ratio, so also check a THIRD drag, where linear keeps adding 0.3
    // (-> 0.9) but compounding would multiply the running total by gain again (-> 1.8, clamped to 1).
    XCTAssertEqual(secondSmall.x, 0.6, accuracy: 1e-9)
    let thirdSmall = TouchOverlayIRGeometry.drag(start: .zero, current: CGPoint(x: 100, y: 0), oldX: secondSmall.x, oldY: secondSmall.y, in: smallRect, gain: 3.0)
    XCTAssertEqual(thirdSmall.x, 0.9, accuracy: 1e-9,
                  "linear accumulation: 0.6 + 0.3 = 0.9; a bug that re-scales the accumulated total would clamp to 1.0 here instead")
  }

  // MARK: Phase 3 — IR area fill-inset scale clamp (task item 1, C9)

  func testClampFillInsetScaleUsesGenericRangeWhenBoundsAreDegenerate() {
    XCTAssertEqual(TouchOverlayIRGeometry.clampFillInsetScale(5.0, baseExtent: 0, boundsExtent: 0), 2.0)
    XCTAssertEqual(TouchOverlayIRGeometry.clampFillInsetScale(0.01, baseExtent: 100, boundsExtent: 0), 0.5)
  }

  func testClampFillInsetScaleCapsAtBoundsEvenBelowGenericUpperBound() {
    // A `.fillInset` base of 342pt inside a 390pt-wide overlay can grow at most ~1.14x before it
    // exceeds the screen — far below the generic 2.0 upper bound `TouchOverlayLayoutStore.
    // scaleRange` allows for the small, fixed-size groups it's calibrated for.
    let clamped = TouchOverlayIRGeometry.clampFillInsetScale(2.0, baseExtent: 342, boundsExtent: 390)
    XCTAssertEqual(clamped, 390.0 / 342.0, accuracy: 1e-9)
    XCTAssertLessThan(clamped, 2.0)
  }

  func testClampFillInsetScaleRespectsGenericLowerBoundWhenRoomy() {
    // Bounds much larger than base: the hard bounds-based max is generous, so the generic 0.5
    // lower bound is still the binding constraint on the small side.
    XCTAssertEqual(TouchOverlayIRGeometry.clampFillInsetScale(0.1, baseExtent: 100, boundsExtent: 1000), 0.5)
  }

  // MARK: Phase 3 — independent width/height store entry (task item 1, C9)

  @MainActor
  func testSizeScaleXYReadsUniformFromThreeElementEntry() {
    let store = TouchOverlayLayoutStore(fileURL: nil)
    store.setSizeScale(1.4, for: .wiiIRPad, padKind: .wiiRemote, orientation: .portrait, defaultCenter: CGPoint(x: 0.5, y: 0.5))
    XCTAssertEqual(store.sizeScaleXY(for: .wiiIRPad, padKind: .wiiRemote, orientation: .portrait), CGSize(width: 1.4, height: 1.4))
  }

  @MainActor
  func testSetIRSizeScaleRoundTripsIndependentAxesAndSurvivesReload() throws {
    let url = temporaryFile()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let store = TouchOverlayLayoutStore(fileURL: url)
    // `bounds.width / baseSize.width` (500/350 ≈ 1.43) must clear the requested 1.2 width scale
    // with room to spare, or `clampFillInsetScale`'s bounds-aware cap (not the plain 0.5...2.0
    // `scaleRange`) clips it before this test can observe the round trip — see that function's
    // doc comment.
    let bounds = CGRect(x: 0, y: 0, width: 500, height: 800)
    let baseSize = CGSize(width: 350, height: 750)
    store.setIRSizeScale(CGSize(width: 1.2, height: 0.7), for: .wiiIRPad, padKind: .wiiRemote, orientation: .portrait,
                        bounds: bounds, baseSize: baseSize, defaultCenter: CGPoint(x: 0.5, y: 0.5))
    let scale = store.sizeScaleXY(for: .wiiIRPad, padKind: .wiiRemote, orientation: .portrait)
    XCTAssertEqual(scale.width, 1.2, accuracy: 1e-6)
    XCTAssertEqual(scale.height, 0.7, accuracy: 1e-6)
    // The single-axis `sizeScale` reader (used by every OTHER group's uniform resize) reads the
    // WIDTH component of an asymmetric entry.
    XCTAssertEqual(store.sizeScale(for: .wiiIRPad, padKind: .wiiRemote, orientation: .portrait), 1.2, accuracy: 1e-6)

    let reloaded = TouchOverlayLayoutStore(fileURL: url)
    let reloadedScale = reloaded.sizeScaleXY(for: .wiiIRPad, padKind: .wiiRemote, orientation: .portrait)
    XCTAssertEqual(reloadedScale.width, 1.2, accuracy: 1e-6)
    XCTAssertEqual(reloadedScale.height, 0.7, accuracy: 1e-6)
  }

  @MainActor
  func testSetIRSizeScaleClampsEachAxisAgainstBounds() {
    let store = TouchOverlayLayoutStore(fileURL: nil)
    let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
    let baseSize = CGSize(width: 342, height: 796) // `TouchOverlayDefaults.irPadMargin` (24) inset.
    store.setIRSizeScale(CGSize(width: 5.0, height: 5.0), for: .wiiIRPad, padKind: .wiiRemote, orientation: .portrait,
                        bounds: bounds, baseSize: baseSize, defaultCenter: CGPoint(x: 0.5, y: 0.5))
    let scale = store.sizeScaleXY(for: .wiiIRPad, padKind: .wiiRemote, orientation: .portrait)
    XCTAssertEqual(scale.width, bounds.width / baseSize.width, accuracy: 1e-6)
    XCTAssertEqual(scale.height, bounds.height / baseSize.height, accuracy: 1e-6)
  }

  @MainActor
  func testSetNormalizedCenterPreservesAllTrailingElementsIncludingAsymmetricScale() {
    // Regression test (task item 2's DSU-adjacent store fix): moving a `wiiIRPad` with an
    // asymmetric `[x, y, sx, sy]` entry used to drop `sy` back to "unset" because
    // `setNormalizedCenter` only ever preserved a single trailing element.
    let store = TouchOverlayLayoutStore(fileURL: nil)
    // Same margin reasoning as `testSetIRSizeScaleRoundTripsIndependentAxesAndSurvivesReload`
    // above: bounds wide enough that 1.3 isn't itself clamped, so this test isolates the
    // trailing-elements bug from the bounds-aware clamp.
    let bounds = CGRect(x: 0, y: 0, width: 500, height: 800)
    let baseSize = CGSize(width: 350, height: 750)
    store.setIRSizeScale(CGSize(width: 1.3, height: 0.6), for: .wiiIRPad, padKind: .wiiRemote, orientation: .portrait,
                        bounds: bounds, baseSize: baseSize, defaultCenter: CGPoint(x: 0.5, y: 0.5))
    store.setNormalizedCenter(CGPoint(x: 0.2, y: 0.3), for: .wiiIRPad, padKind: .wiiRemote, orientation: .portrait)
    let scale = store.sizeScaleXY(for: .wiiIRPad, padKind: .wiiRemote, orientation: .portrait)
    XCTAssertEqual(scale.width, 1.3, accuracy: 1e-6)
    XCTAssertEqual(scale.height, 0.6, accuracy: 1e-6, "sy must survive a plain move, not collapse back to sx")
    XCTAssertEqual(store.normalizedCenter(for: .wiiIRPad, padKind: .wiiRemote, orientation: .portrait), CGPoint(x: 0.2, y: 0.3))
  }

  @MainActor
  func testResetGroupClearsOnlyThatGroup() {
    let store = TouchOverlayLayoutStore(fileURL: nil)
    store.setNormalizedCenter(CGPoint(x: 0.1, y: 0.1), for: .wiiIRPad, padKind: .wiiRemote, orientation: .portrait)
    store.setNormalizedCenter(CGPoint(x: 0.2, y: 0.2), for: .wiiDpad, padKind: .wiiRemote, orientation: .portrait)
    store.resetGroup(.wiiIRPad, padKind: .wiiRemote)
    XCTAssertNil(store.normalizedCenter(for: .wiiIRPad, padKind: .wiiRemote, orientation: .portrait))
    XCTAssertEqual(store.normalizedCenter(for: .wiiDpad, padKind: .wiiRemote, orientation: .portrait), CGPoint(x: 0.2, y: 0.2),
                  "resetting the IR pad must not discard the rest of the layout")
  }

  // MARK: Phase 3 — edit-mode mutual exclusion (task item 1, C9, design §9)

  func testEditModeNoneShowsNoChromeAnywhere() {
    for group in TouchOverlayGroup.allCases {
      XCTAssertFalse(TouchOverlayEditMode.none.showsChrome(for: group))
    }
    XCTAssertFalse(TouchOverlayEditMode.none.inputSuppressed)
  }

  func testEditModeLayoutShowsChromeForEveryGroupExceptTheIRPad() {
    // `wiiIRPad` is excluded from `.layout` mode specifically (its only resize path is the
    // bounds-aware `.irArea` editor now) — see `showsChrome`'s doc comment.
    for group in TouchOverlayGroup.allCases where group != .wiiIRPad {
      XCTAssertTrue(TouchOverlayEditMode.layout.showsChrome(for: group))
    }
    XCTAssertFalse(TouchOverlayEditMode.layout.showsChrome(for: .wiiIRPad))
    XCTAssertTrue(TouchOverlayEditMode.layout.inputSuppressed)
  }

  func testEditModeIRAreaShowsChromeOnlyForTheIRPad() {
    XCTAssertTrue(TouchOverlayEditMode.irArea.showsChrome(for: .wiiIRPad))
    for group in TouchOverlayGroup.allCases where group != .wiiIRPad {
      XCTAssertFalse(TouchOverlayEditMode.irArea.showsChrome(for: group),
                    "\(group) must not show layout-editor chrome while editing the IR area")
    }
    XCTAssertTrue(TouchOverlayEditMode.irArea.inputSuppressed,
                 "every group's INPUT must still be suppressed in .irArea mode, even the ones with no chrome")
  }

  func testEditModesAreMutuallyExclusiveByConstruction() {
    // There is exactly one `TouchOverlayEditMode` value at a time (it's an enum, not two
    // independent Bools), so ".layout chrome" and ".irArea chrome" can never both be showing for
    // the SAME group at once — the case list itself is the proof, not a runtime check.
    XCTAssertEqual(TouchOverlayEditMode.allCases, [.none, .layout, .irArea])
  }
}
#endif
