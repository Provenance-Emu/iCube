// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import XCTest
@testable import iCube

final class TouchOverlayHapticsTests: XCTestCase {
  private typealias Hit = SkinOverlayInput.Hit

  // MARK: Sticks

  /// Feeds a touch's samples (nil = lift) through one tracker and returns what each played.
  private func events(_ samples: [CGPoint?]) -> [TouchHapticEvent?] {
    var tracker = StickHapticTracker()
    return samples.map { tracker.update(axes: $0) }
  }

  func testStickPlaysOnTouchDownOnly() {
    XCTAssertEqual(events([CGPoint(x: 0.1, y: 0), CGPoint(x: 0.3, y: 0.2), CGPoint(x: -0.5, y: 0.4), nil]),
                   [.stickTouchDown, nil, nil, nil], "no haptic on an ordinary move sample or on release")
  }

  func testStickPlaysEveryNewTouch() {
    XCTAssertEqual(events([.zero, nil, CGPoint(x: 0.2, y: 0), nil]),
                   [.stickTouchDown, nil, .stickTouchDown, nil])
  }

  func testStickRimPlaysOnceWhileHeldAtTheEdge() {
    XCTAssertEqual(events([.zero, CGPoint(x: 0.96, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: -1, y: 0), CGPoint(x: 0.85, y: 0)]),
                   [.stickTouchDown, .stickRim, nil, nil, nil], "circling the rim, or easing back inside the exit band, does not re-play")
  }

  func testStickRimReArmsOnlyAfterComingBackInside() {
    XCTAssertEqual(events([.zero, CGPoint(x: 1, y: 0), CGPoint(x: 0.5, y: 0), CGPoint(x: 0, y: -1)]),
                   [.stickTouchDown, .stickRim, nil, .stickRim])
  }

  func testStickTouchLandingOnTheRimPlaysTheTouchDownOnly() {
    XCTAssertEqual(events([CGPoint(x: 1, y: 0), CGPoint(x: 0.98, y: 0.1), CGPoint(x: 0.4, y: 0), CGPoint(x: 1, y: 0)]),
                   [.stickTouchDown, nil, nil, .stickRim])
  }

  func testStickRimIsMeasuredOnTheDiagonal() {
    XCTAssertEqual(events([.zero, CGPoint(x: 0.7, y: 0.7)]), [.stickTouchDown, .stickRim], "|(0.7, 0.7)| is 0.99")
  }

  func testStickReleaseResetsTheRim() {
    XCTAssertEqual(events([.zero, CGPoint(x: 1, y: 0), nil, .zero, CGPoint(x: 1, y: 0)]),
                   [.stickTouchDown, .stickRim, nil, .stickTouchDown, .stickRim])
  }

  // MARK: Button clusters

  func testClusterPlaysWhenAnythingNewIsPressed() {
    XCTAssertTrue(TouchHapticRules.pressesSomethingNew(previous: [], now: ["gc.a"]))
    XCTAssertTrue(TouchHapticRules.pressesSomethingNew(previous: ["gc.b"], now: ["gc.a", "gc.b"]), "A while holding B")
    XCTAssertTrue(TouchHapticRules.pressesSomethingNew(previous: ["gc.b"], now: ["gc.a"]), "sliding from B onto A")
    XCTAssertTrue(TouchHapticRules.pressesSomethingNew(previous: [], now: ["gc.a", "gc.b"]))
  }

  func testClusterDoesNotPlayOnReleaseOrNoChange() {
    XCTAssertFalse(TouchHapticRules.pressesSomethingNew(previous: ["gc.a", "gc.b"], now: ["gc.a"]))
    XCTAssertFalse(TouchHapticRules.pressesSomethingNew(previous: ["gc.a"], now: []))
    XCTAssertFalse(TouchHapticRules.pressesSomethingNew(previous: ["gc.a"], now: ["gc.a"]))
    XCTAssertFalse(TouchHapticRules.pressesSomethingNew(previous: Set<String>(), now: []))
  }

  // MARK: Skins

  func testSkinPlaysForAButtonPressedWhileTheDpadIsHeld() {
    let dpadUp: Set<Hit> = [.direction(item: 0, .up)]
    XCTAssertTrue(SkinOverlayInput.pressesNewItem(from: dpadUp, to: dpadUp.union([.item(1)])),
                  "used to be silent: the old rule only played when every finger was off the skin")
    XCTAssertTrue(SkinOverlayInput.pressesNewItem(from: [.item(1)], to: [.item(1), .item(2)]), "A while holding B")
  }

  func testSkinDpadPlaysOnFirstDirectionOnly() {
    XCTAssertTrue(SkinOverlayInput.pressesNewItem(from: [], to: [.direction(item: 0, .up)]))
    XCTAssertFalse(SkinOverlayInput.pressesNewItem(from: [.direction(item: 0, .up)], to: [.direction(item: 0, .up), .direction(item: 0, .right)]),
                   "rolling into a diagonal")
    XCTAssertFalse(SkinOverlayInput.pressesNewItem(from: [.direction(item: 0, .up)], to: [.direction(item: 0, .down)]),
                   "rolling to the opposite direction")
  }

  func testSkinDoesNotPlayOnRelease() {
    XCTAssertFalse(SkinOverlayInput.pressesNewItem(from: [.item(1), .direction(item: 0, .left)], to: [.item(1)]))
    XCTAssertFalse(SkinOverlayInput.pressesNewItem(from: [.item(1)], to: []))
  }
}
#endif
