// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// `PointerSourceResolver` (design B2, plan call 4): one table per platform and pad class, the
/// override rules, and the labels every pointer row shows.
final class PointerSourceResolverTests: XCTestCase {

  private static let gyro = PadCapabilities(hasGyro: true, hasTouchpad: false)
  private static let touchpad = PadCapabilities(hasGyro: false, hasTouchpad: true)
  private static let both = PadCapabilities(hasGyro: true, hasTouchpad: true)
  private static let plain = PadCapabilities()

  private struct Row {
    let player1: PointerPlayer1
    let remoteHasMotion: Bool
    let preferredMode: PointerMode
    let expected: PointerSource
    let line: UInt
  }

  private func check(_ rows: [Row], platform: PlatformKind, override: PointerSource.Kind? = nil) {
    for row in rows {
      XCTAssertEqual(
        PointerSourceResolver.resolve(
          player1: row.player1, remoteHasMotion: row.remoteHasMotion, platform: platform,
          preferredMode: row.preferredMode, userOverride: override),
        row.expected, line: row.line)
    }
  }

  // MARK: Automatic, per platform and pad class

  func test_tvOS_automatic() {
    check([
      Row(player1: .pad(name: "DualSense", capabilities: Self.both), remoteHasMotion: true, preferredMode: .touchFollow,
          expected: .padGyro(padName: "DualSense"), line: #line),
      Row(player1: .pad(name: "DualSense", capabilities: Self.gyro), remoteHasMotion: false, preferredMode: .touchFollow,
          expected: .padGyro(padName: "DualSense"), line: #line),
      Row(player1: .pad(name: "Pad", capabilities: Self.touchpad), remoteHasMotion: true, preferredMode: .gyro,
          expected: .padTouchpad(padName: "Pad"), line: #line),
      Row(player1: .pad(name: "Xbox", capabilities: Self.plain), remoteHasMotion: true, preferredMode: .touchFollow,
          expected: .remoteGyro, line: #line),
      Row(player1: .pad(name: "Xbox", capabilities: Self.plain), remoteHasMotion: false, preferredMode: .touchFollow,
          expected: .none, line: #line),
      // tvOS has no on-screen controls: a touchscreen-bound Wii Remote 1 is idle, so the remote can aim.
      Row(player1: .touchscreen, remoteHasMotion: true, preferredMode: .gyro, expected: .remoteGyro, line: #line),
      Row(player1: .touchscreen, remoteHasMotion: false, preferredMode: .gyro, expected: .none, line: #line),
      Row(player1: .none, remoteHasMotion: true, preferredMode: .gyro, expected: .none, line: #line),
    ], platform: .tvos)
  }

  func test_iOS_automatic() {
    check([
      Row(player1: .pad(name: "DualSense", capabilities: Self.both), remoteHasMotion: false, preferredMode: .gyro,
          expected: .padGyro(padName: "DualSense"), line: #line),
      Row(player1: .pad(name: "Pad", capabilities: Self.touchpad), remoteHasMotion: false, preferredMode: .gyro,
          expected: .padTouchpad(padName: "Pad"), line: #line),
      // Plan call 4: a plain pad gets no phone-gyro pointer unless the user picks it.
      Row(player1: .pad(name: "Xbox", capabilities: Self.plain), remoteHasMotion: false, preferredMode: .gyro,
          expected: .none, line: #line),
      // There is no Siri Remote on iOS, whatever the flag says.
      Row(player1: .pad(name: "Xbox", capabilities: Self.plain), remoteHasMotion: true, preferredMode: .gyro,
          expected: .none, line: #line),
      Row(player1: .touchscreen, remoteHasMotion: false, preferredMode: .gyro, expected: .deviceGyro, line: #line),
      Row(player1: .touchscreen, remoteHasMotion: false, preferredMode: .touchFollow, expected: .touchFollow, line: #line),
      Row(player1: .touchscreen, remoteHasMotion: false, preferredMode: .touchDrag, expected: .touchDrag, line: #line),
      Row(player1: .none, remoteHasMotion: false, preferredMode: .gyro, expected: .none, line: #line),
    ], platform: .ios)
  }

  // MARK: Override

  func test_override_winsWhenTheSetupCanHonourIt() {
    check([
      Row(player1: .pad(name: "DualSense", capabilities: Self.gyro), remoteHasMotion: true, preferredMode: .gyro,
          expected: .remoteGyro, line: #line),
    ], platform: .tvos, override: .remoteGyro)
    check([
      Row(player1: .pad(name: "DualSense", capabilities: Self.both), remoteHasMotion: false, preferredMode: .gyro,
          expected: .padTouchpad(padName: "DualSense"), line: #line),
    ], platform: .tvos, override: .padTouchpad)
    check([
      Row(player1: .pad(name: "Xbox", capabilities: Self.plain), remoteHasMotion: false, preferredMode: .touchFollow,
          expected: .deviceGyro, line: #line),
    ], platform: .ios, override: .deviceGyro)
  }

  func test_override_theSetupCannotHonour_fallsThroughToAutomatic() {
    check([
      // The remote has no motion.
      Row(player1: .pad(name: "DualSense", capabilities: Self.gyro), remoteHasMotion: false, preferredMode: .gyro,
          expected: .padGyro(padName: "DualSense"), line: #line),
    ], platform: .tvos, override: .remoteGyro)
    check([
      // The gyro pad left for a plain one.
      Row(player1: .pad(name: "Xbox", capabilities: Self.plain), remoteHasMotion: true, preferredMode: .gyro,
          expected: .remoteGyro, line: #line),
    ], platform: .tvos, override: .padGyro)
    check([
      // The device's gyro does not exist on tvOS.
      Row(player1: .pad(name: "Xbox", capabilities: Self.plain), remoteHasMotion: false, preferredMode: .gyro,
          expected: .none, line: #line),
    ], platform: .tvos, override: .deviceGyro)
  }

  /// The iOS touchscreen chooses with its own Follow / Drag / Gyro row; the stored override is for pads.
  func test_override_isIgnoredOnTheIOSTouchscreen() {
    check([
      Row(player1: .touchscreen, remoteHasMotion: false, preferredMode: .touchDrag, expected: .touchDrag, line: #line),
    ], platform: .ios, override: .deviceGyro)
  }

  // MARK: Choices

  func test_choices_tvOS_listEverySourceTheSetupCanDrive() {
    XCTAssertEqual(
      PointerSourceResolver.choices(player1: .pad(name: "DS", capabilities: Self.both), remoteHasMotion: true, platform: .tvos),
      [.padGyro(padName: "DS"), .padTouchpad(padName: "DS"), .remoteGyro])
    XCTAssertEqual(
      PointerSourceResolver.choices(player1: .pad(name: "Xbox", capabilities: Self.plain), remoteHasMotion: false, platform: .tvos), [])
    XCTAssertEqual(PointerSourceResolver.choices(player1: .touchscreen, remoteHasMotion: true, platform: .tvos), [.remoteGyro])
  }

  /// The iPhone gyro for a pad has no binding yet, and the touchscreen has its own mode row.
  func test_choices_iOS_leaveOutTheDeviceGyroAndTheTouchscreen() {
    XCTAssertEqual(
      PointerSourceResolver.choices(player1: .pad(name: "DS", capabilities: Self.gyro), remoteHasMotion: false, platform: .ios),
      [.padGyro(padName: "DS")])
    XCTAssertEqual(PointerSourceResolver.choices(player1: .touchscreen, remoteHasMotion: false, platform: .ios), [])
  }

  // MARK: Model and labels

  func test_labels() {
    XCTAssertEqual(PointerSource.padGyro(padName: "DualSense").label(deviceModel: "iPad"), "DualSense gyro")
    XCTAssertEqual(PointerSource.padTouchpad(padName: "DualSense").label(deviceModel: "iPad"), "DualSense touchpad")
    XCTAssertEqual(PointerSource.remoteGyro.label(deviceModel: "Apple TV"), "Siri Remote")
    XCTAssertEqual(PointerSource.deviceGyro.label(deviceModel: "iPad"), "iPad gyro")
    XCTAssertEqual(PointerSource.deviceGyro.label(deviceModel: "iPhone"), "iPhone gyro")
    XCTAssertEqual(PointerSource.touchFollow.label(deviceModel: "iPhone"), "Touch (Follow)")
    XCTAssertEqual(PointerSource.touchDrag.label(deviceModel: "iPhone"), "Touch (Drag)")
    XCTAssertEqual(PointerSource.none.label(deviceModel: "iPhone"), "No pointer")
  }

  func test_model_headlineAndExplanation() {
    let remote = PointerSourceModel.make(
      player1: .pad(name: "Xbox", capabilities: Self.plain), remoteHasMotion: true, platform: .tvos,
      preferredMode: .touchFollow, userOverride: nil, deviceModel: "Apple TV")
    XCTAssertEqual(remote.headline, "Pointer: Siri Remote")
    XCTAssertNil(remote.explanation)
    XCTAssertEqual(remote.options.map(\.0), ["Automatic", "Siri Remote"])
    XCTAssertEqual(remote.selectedTag, PointerSourceModel.automaticTag)

    let nothing = PointerSourceModel.make(
      player1: .pad(name: "Xbox", capabilities: Self.plain), remoteHasMotion: false, platform: .tvos,
      preferredMode: .touchFollow, userOverride: nil, deviceModel: "Apple TV")
    XCTAssertEqual(nothing.headline, "No pointer")
    XCTAssertEqual(nothing.explanation, "Connect a controller with motion, or use the Siri Remote.")
    XCTAssertTrue(nothing.choices.isEmpty)
  }

  /// A stored override the setup cannot honour shows as Automatic, so the row never reads "—".
  func test_model_unhonouredOverride_selectsAutomatic() {
    let model = PointerSourceModel.make(
      player1: .pad(name: "DS", capabilities: Self.gyro), remoteHasMotion: false, platform: .tvos,
      preferredMode: .gyro, userOverride: .remoteGyro, deviceModel: "Apple TV")
    XCTAssertNil(model.override)
    XCTAssertEqual(model.selectedTag, PointerSourceModel.automaticTag)
    XCTAssertEqual(PointerSourceModel.override(forTag: AnyHashable("remoteGyro")), .remoteGyro)
    XCTAssertNil(PointerSourceModel.override(forTag: AnyHashable(PointerSourceModel.automaticTag)))
  }

  func test_player1_fromTheBoundQualifier() {
    let pads = [
      ConnectedPadState(qualifier: "MFi/0/DualSense", name: "DualSense", batteryPercent: nil, isCharging: false, playerLabel: nil,
                        hasGyro: true, hasTouchpad: true),
    ]
    XCTAssertEqual(PointerPlayer1.from(qualifier: "", pads: pads), .none)
    XCTAssertEqual(PointerPlayer1.from(qualifier: "iOS/4/Touchscreen", pads: pads), .touchscreen)
    XCTAssertEqual(PointerPlayer1.from(qualifier: "MFi/0/DualSense", pads: pads), .pad(name: "DualSense", capabilities: Self.both))
    XCTAssertEqual(
      PointerPlayer1.from(qualifier: "DSUClient/0/Pad C", pads: pads), .pad(name: "Pad C", capabilities: Self.plain),
      "a device outside the pad list has no known capabilities")
  }

  func test_overrideStore_roundTrips() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "PointerSourceResolverTests"))
    defaults.removePersistentDomain(forName: "PointerSourceResolverTests")
    let store = PointerSourceOverrideStore(defaults: defaults)
    XCTAssertNil(store.value)
    store.value = .remoteGyro
    XCTAssertEqual(defaults.string(forKey: "wii_pointer_source_override"), "remoteGyro")
    XCTAssertEqual(store.value, .remoteGyro)
    store.value = nil
    XCTAssertNil(defaults.object(forKey: "wii_pointer_source_override"))
  }
}
