// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI
import UIKit
import XCTest

@testable import iCube

/// Touching the on-screen controls must not re-render them per touch sample: a finger sliding inside
/// one button, or a stick moving, used to re-run the whole cluster's body (and every button's art) at
/// the touch rate while the game ran underneath. These pin the "only on a change" rules.
final class TouchOverlayClusterUpdateTests: XCTestCase {
  private let anchors = (0 ..< 3).map { _ in NSObject() }

  private func touch(_ index: Int, _ x: CGFloat, _ y: CGFloat) -> TouchOverlaySurface.Touch {
    TouchOverlaySurface.Touch(id: ObjectIdentifier(anchors[index]), location: CGPoint(x: x, y: y), force: 0, maximumPossibleForce: 0)
  }

  /// Left half is "a", right half is "b".
  private func hit(_ point: CGPoint) -> Set<String> {
    point.x < 50 ? ["a"] : ["b"]
  }

  func testMovingInsideTheSameRegionIsNotAChange() {
    let live = TouchOverlayLiveTouches()
    live.apply(.began, [touch(0, 10, 10)])
    let press = TouchOverlayClusterUpdate(previous: [], touches: live.values, hitTest: hit)
    XCTAssertTrue(press.changed)
    XCTAssertEqual(press.pressed, ["a"])

    for x in stride(from: CGFloat(11), to: 49, by: 3) {
      live.apply(.moved, [touch(0, x, 20)])
      let update = TouchOverlayClusterUpdate(previous: press.now, touches: live.values, hitTest: hit)
      XCTAssertFalse(update.changed, "move to x=\(x) stayed on a")
      XCTAssertEqual(update.now, ["a"])
    }
  }

  func testSlidingOntoANeighbourReleasesAndPresses() {
    let live = TouchOverlayLiveTouches()
    live.apply(.began, [touch(0, 10, 10)])
    live.apply(.moved, [touch(0, 80, 10)])
    let update = TouchOverlayClusterUpdate(previous: ["a"], touches: live.values, hitTest: hit)
    XCTAssertTrue(update.changed)
    XCTAssertEqual(update.pressed, ["b"])
    XCTAssertEqual(update.released, ["a"])
  }

  func testTwoFingersOnOneRegionHoldItUntilBothLift() {
    let live = TouchOverlayLiveTouches()
    live.apply(.began, [touch(0, 10, 10), touch(1, 20, 20)])
    var update = TouchOverlayClusterUpdate(previous: [], touches: live.values, hitTest: hit)
    XCTAssertEqual(update.pressed, ["a"])

    live.apply(.ended, [touch(0, 10, 10)])
    update = TouchOverlayClusterUpdate(previous: ["a"], touches: live.values, hitTest: hit)
    XCTAssertFalse(update.changed, "the second finger still holds a")

    live.apply(.cancelled, [touch(1, 20, 20)])
    update = TouchOverlayClusterUpdate(previous: ["a"], touches: live.values, hitTest: hit)
    XCTAssertTrue(update.changed)
    XCTAssertEqual(update.released, ["a"])
    XCTAssertTrue(update.now.isEmpty)
  }

  func testRemoveAllForgetsEveryTouch() {
    let live = TouchOverlayLiveTouches()
    live.apply(.began, [touch(0, 10, 10), touch(1, 80, 10)])
    live.removeAll()
    XCTAssertTrue(TouchOverlayClusterUpdate(previous: ["a", "b"], touches: live.values, hitTest: hit).now.isEmpty)
  }
}

#if DEBUG
/// Hosts the real control views, feeds their UIKit touch surface fabricated samples, and counts body
/// evaluations through `TouchOverlayRenderProbe`.
@MainActor
final class TouchOverlayRenderCountTests: XCTestCase {
  /// A Touchscreen device id the view tests leave alone; cleared after each test.
  private let deviceId = 3
  private let anchor = NSObject()
  private var window: UIWindow?

  override func tearDown() {
    window?.isHidden = true
    window = nil
    TCManagerInterface.clearAll(forController: deviceId)
    super.tearDown()
  }

  private func host<V: View>(_ view: V, size: CGSize) throws -> [TouchOverlaySurface.SurfaceView] {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: size)
    window.rootViewController = UIHostingController(rootView: view)
    window.isHidden = false
    window.layoutIfNeeded()
    self.window = window
    settle()
    return surfaces(in: window)
  }

  private func surfaces(in view: UIView) -> [TouchOverlaySurface.SurfaceView] {
    var found: [TouchOverlaySurface.SurfaceView] = []
    if let surface = view as? TouchOverlaySurface.SurfaceView { found.append(surface) }
    for subview in view.subviews { found += surfaces(in: subview) }
    return found
  }

  private func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
  }

  private func send(_ surface: TouchOverlaySurface.SurfaceView, _ phase: TouchOverlaySurface.Phase, _ point: CGPoint) {
    let sample = TouchOverlaySurface.Touch(id: ObjectIdentifier(anchor), location: point, force: 0, maximumPossibleForce: 0)
    surface.onTouches?(phase, [sample])
    settle()
  }

  func testSlidingInsideAButtonDoesNotReRenderTheCluster() throws {
    let controls = [
      TouchOverlayControl(id: "gc.a", kind: .button(id: 0), frame: CGRect(x: 0, y: 0, width: 60, height: 60)),
      TouchOverlayControl(id: "gc.b", kind: .button(id: 1), frame: CGRect(x: 80, y: 0, width: 60, height: 60)),
    ]
    let view = TouchOverlayButtonClusterView(controls: controls, deviceId: deviceId, variant: .gameCube,
                                             groupSize: CGSize(width: 140, height: 60), scale: 1, isEditing: false)
    let surface = try XCTUnwrap(host(view, size: CGSize(width: 140, height: 60)).first)

    send(surface, .began, CGPoint(x: 30, y: 30))
    TouchOverlayRenderProbe.reset()
    for step in 0 ..< 20 {
      send(surface, .moved, CGPoint(x: 10 + CGFloat(step * 2), y: 30))
    }
    XCTAssertEqual(TouchOverlayRenderProbe.count(.cluster), 0)
    XCTAssertEqual(TouchOverlayRenderProbe.count(.buttonCluster), 0)

    // A real transition still re-renders (the highlight has to move).
    send(surface, .moved, CGPoint(x: 110, y: 30))
    XCTAssertGreaterThan(TouchOverlayRenderProbe.count(.buttonCluster), 0)
    send(surface, .ended, CGPoint(x: 110, y: 30))
  }

  func testMovingTheStickReRendersOnlyTheKnob() throws {
    let size = CGSize(width: 150, height: 150)
    let view = TouchOverlayStickView(baseId: 10, deviceId: deviceId, variant: .wii, groupSize: size, isEditing: false)
    let surface = try XCTUnwrap(host(view, size: size).first)

    send(surface, .began, CGPoint(x: 75, y: 75))
    TouchOverlayRenderProbe.reset()
    for step in 0 ..< 20 {
      send(surface, .moved, CGPoint(x: 75 + CGFloat(step), y: 75 - CGFloat(step)))
    }
    XCTAssertGreaterThan(TouchOverlayRenderProbe.count(.stickKnob), 0, "the knob must follow the finger")
    XCTAssertEqual(TouchOverlayRenderProbe.count(.stick), 0)
    XCTAssertEqual(TouchOverlayRenderProbe.count(.stickBase), 0)
    send(surface, .ended, CGPoint(x: 95, y: 55))
  }

  /// Pressing a skin button re-renders the skin's touch layer (it owns the pressed set); its sticks
  /// must not resolve their knob file again (symlink resolution and stats on the main thread).
  func testPressingASkinButtonDoesNotReResolveTheKnobArt() throws {
    let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestCube", withExtension: "deltaskin", subdirectory: "Skins"))
    let info = try SkinInfo.load(directory: directory)
    let skin = InstalledSkin(id: info.identifier, name: info.name, gameType: info.gameType, directory: directory)
    let device = try XCTUnwrap(TouchOverlayPreviewDevice.all.first { !$0.isPad })
    let view = SkinOverlayView(skin: skin, padKind: .gameCube, deviceId: deviceId, previewDevice: device.skinDevice, onAction: { _ in })
    let surfaces = try host(view, size: device.size(.portrait))
    // The button surface covers the whole skin; each stick has its own, smaller one. The skin lays out
    // on the size the host gave it, which is the button surface's own bounds.
    let cluster = try XCTUnwrap(surfaces.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
    let canvas = cluster.bounds.size
    let representation = try XCTUnwrap(SkinOverlayInput.representation(info: info, isPad: false, orientation: .portrait))
    let layout = SkinLayout.make(representation, canvas: canvas)
    let input = SkinOverlayInput(layout: layout, padKind: .gameCube)
    XCTAssertFalse(input.sticks.isEmpty, "the fixture has a thumbstick")
    let stickFrames = input.sticks.map(\.hitFrame)
    let button = try XCTUnwrap(layout.items.map(\.hitFrame).first { frame in
      let center = CGPoint(x: frame.midX, y: frame.midY)
      return !stickFrames.contains { $0.contains(center) } && !input.hits(at: center, previous: []).isEmpty
    })

    TouchOverlayRenderProbe.reset()
    send(cluster, .began, CGPoint(x: button.midX, y: button.midY))
    XCTAssertGreaterThan(TouchOverlayRenderProbe.count(.skinTouchLayer), 0, "the press reached the skin")
    send(cluster, .ended, CGPoint(x: button.midX, y: button.midY))
    XCTAssertEqual(TouchOverlayRenderProbe.count(.skinKnobResolve), 0)
  }
}
#endif

/// The motion settings cache must follow a defaults write immediately, or a Pointer & Motion change
/// would not reach the very next sample.
final class MotionSettingsCacheTests: XCTestCase {
  private let suite = "MotionSettingsCacheTests"
  private var store: UserDefaults!

  override func setUp() {
    super.setUp()
    UserDefaults().removePersistentDomain(forName: suite)
    store = UserDefaults(suiteName: suite)
    MotionSettings.registerDefaults(in: store)
  }

  override func tearDown() {
    UserDefaults().removePersistentDomain(forName: suite)
    super.tearDown()
  }

  func testSnapshotFollowsAWriteImmediately() {
    let cache = MotionSettingsCache(store: store)
    XCTAssertFalse(cache.snapshot.invertRoll)
    XCTAssertEqual(cache.snapshot.gyroPointerSensitivity, 1)

    MotionSettings.setInvertRoll(true, in: store)
    MotionSettings.setGyroPointerSensitivity(0.5, in: store)
    store.set(true, forKey: MotionSettings.Snapshot.inputDebugKey)

    XCTAssertTrue(cache.snapshot.invertRoll)
    XCTAssertEqual(cache.snapshot.gyroPointerSensitivity, 0.5)
    XCTAssertTrue(cache.snapshot.inputDebug)

    store.removeObject(forKey: MotionSettings.Key.invertRoll)
    XCTAssertFalse(cache.snapshot.invertRoll, "back to the registered default")
  }

  func testSnapshotIsReusedUntilSomethingChanges() {
    let cache = MotionSettingsCache(store: store, center: NotificationCenter())
    XCTAssertTrue(cache.snapshot.full6DOF)
    // A private center hears no change notification, so the cached value stands...
    store.set(false, forKey: MotionSettings.Key.full6DOF)
    XCTAssertTrue(cache.snapshot.full6DOF)
    // ...until it is invalidated.
    cache.invalidate()
    XCTAssertFalse(cache.snapshot.full6DOF)
  }

  func testSnapshotMatchesTheIndividualReaders() {
    store.set(true, forKey: MotionSettings.Key.useYawForHorizontal)
    store.set(true, forKey: MotionSettings.Key.invertPitch)
    store.set(false, forKey: MotionSettings.Key.enhancedShakeDetection)
    store.set(false, forKey: MotionSettings.Key.wiimoteIMU)
    store.set(true, forKey: MotionSettings.Key.nunchukIMU)
    store.set(-3.0, forKey: MotionSettings.Key.gyroPointerSensitivity)
    let snapshot = MotionSettingsCache(store: store).snapshot
    XCTAssertEqual(snapshot.useYawForHorizontal, MotionSettings.useYawForHorizontal(in: store))
    XCTAssertEqual(snapshot.invertPitch, MotionSettings.invertPitch(in: store))
    XCTAssertEqual(snapshot.enhancedShakeDetection, MotionSettings.enhancedShakeDetection(in: store))
    XCTAssertEqual(snapshot.full6DOF, MotionSettings.full6DOF(in: store))
    XCTAssertEqual(snapshot.wiimoteIMU, MotionSettings.wiimoteIMU(in: store))
    XCTAssertEqual(snapshot.nunchukIMU, MotionSettings.nunchukIMU(in: store))
    XCTAssertEqual(snapshot.gyroPointerSensitivity, 1, "a non-positive sensitivity reads as neutral")
  }
}

/// `TCManagerInterface` caches the DSU knobs and `input_debug`; a write must apply to the next axis
/// write without any delay.
final class TCManagerInterfaceDefaultsCacheTests: XCTestCase {
  private let controller = 3
  private let defaults = UserDefaults.standard
  private let keys = ["dsu_gyro_gain", "dsu_deadzone", "dsu_smoothing", "input_debug"]
  private var saved: [String: Any] = [:]
  /// GC main stick X+ (`TCButtonType.mainStickRight`): an ordinary analog axis.
  private let stickRight = 14

  override func setUp() {
    super.setUp()
    saved = [:]
    for key in keys {
      if let value = defaults.object(forKey: key) { saved[key] = value }
      defaults.removeObject(forKey: key)
    }
    TCManagerInterface.clearAll(forController: controller)
  }

  override func tearDown() {
    for key in keys {
      if let value = saved[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
    TCManagerInterface.clearAll(forController: controller)
    super.tearDown()
  }

  private func roundTrip(_ value: Float) -> Float {
    TCManagerInterface.setAxisValueFor(stickRight, controller: controller, value: value)
    return TCManagerInterface.axisValue(for: stickRight, controller: controller)
  }

  func testDeadzoneAndGainChangesApplyToTheNextWrite() {
    XCTAssertEqual(roundTrip(0.25), 0.25, accuracy: 0.0001, "no knobs set: passthrough")

    defaults.set(0.5, forKey: "dsu_gyro_gain")
    XCTAssertEqual(roundTrip(0.4), 0.2, accuracy: 0.0001)

    defaults.set(0.2, forKey: "dsu_deadzone")
    XCTAssertEqual(roundTrip(0.1), 0, accuracy: 0.0001, "inside the deadzone")

    defaults.removeObject(forKey: "dsu_gyro_gain")
    defaults.removeObject(forKey: "dsu_deadzone")
    XCTAssertEqual(roundTrip(0.1), 0.1, accuracy: 0.0001)
  }

  func testInputDebugFlagFollowsTheDefault() {
    XCTAssertFalse(TCManagerInterface.inputDebugEnabled)
    defaults.set(true, forKey: "input_debug")
    XCTAssertTrue(TCManagerInterface.inputDebugEnabled)
    defaults.set(false, forKey: "input_debug")
    XCTAssertFalse(TCManagerInterface.inputDebugEnabled)
  }
}
#endif
