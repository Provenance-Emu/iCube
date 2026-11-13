// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import simd

@testable import iCube

/// Covers `MotionTestModelBuilder`: which sections and rows each source gets, and that the line a
/// tester reads follows the controller's raw reading through the core's mapping. Pure, as
/// `ControllerHubModelBuilderTests`.
final class MotionTestModelBuilderTests: XCTestCase {

  private func flags(
    rotationRate: Bool = true, gravityAndUser: Bool = false, attitude: Bool = false, manual: Bool = false, active: Bool = false
  ) -> MotionSensorFlags {
    MotionSensorFlags(
      hasRotationRate: rotationRate, hasGravityAndUserAcceleration: gravityAndUser, hasAttitude: attitude,
      sensorsRequireManualActivation: manual, sensorsActive: active)
  }

  /// A pad lying flat, face up, unless told otherwise (GCMotion: gravity pulls along -z).
  private func pad(
    _ id: String = "pad-0", name: String = "DualSense Wireless Controller", isMenuRemote: Bool = false,
    acceleration: SIMD3<Double> = SIMD3(0, 0, -1), rotationRate: SIMD3<Double> = .zero, flags: MotionSensorFlags? = nil
  ) -> MotionTestSource {
    .controller(
      id: id, name: name, isMenuRemote: isMenuRemote, acceleration: acceleration, rotationRate: rotationRate,
      flags: flags ?? self.flags())
  }

  private func make(_ sources: [MotionTestSource], device: MotionTestSource? = nil, deviceAvailable: Bool = false,
                    platform: PlatformKind = .ios) -> MenuModel {
    MotionTestModelBuilder.make(
      state: MotionTestState(sources: sources, device: device, deviceMotionAvailable: deviceAvailable), platform: platform)
  }

  private func ids(_ model: MenuModel, section id: String) -> [String] {
    model.sections.first { $0.id == id }?.items.map(\.id) ?? []
  }

  // MARK: Sections

  func test_iOS_listsControllersThenTheDeviceThenRemotes() {
    let model = make([pad("pad-0", name: "Siri Remote", isMenuRemote: true), pad("pad-1")])
    XCTAssertEqual(model.sections.map(\.id), ["motion-pad-1", MotionTestModelBuilder.deviceSectionID, "motion-pad-0"])
    XCTAssertEqual(model.sections.map(\.header), ["DualSense Wireless Controller", MotionTestModelBuilder.deviceHeader, "Siri Remote"])
  }

  func test_tvOS_hasNoDeviceSection() {
    let model = make([pad()], platform: .tvos)
    XCTAssertEqual(model.sections.map(\.id), ["motion-pad-0"])
  }

  /// With no gamepad, the list still says so, and a Siri Remote is not one.
  func test_noControllers_showsThePlaceholderFirst() {
    let model = make([pad("pad-0", name: "Siri Remote", isMenuRemote: true)], platform: .tvos)
    XCTAssertEqual(model.sections.map(\.id), ["motion-controllers", "motion-pad-0"])
    XCTAssertEqual(ids(model, section: "motion-controllers"), [MotionTestModelBuilder.noControllersRowID])
  }

  /// A tvOS list scrolls only by focus: every row must take it.
  func test_everyRowIsFocusable() {
    for platform in [PlatformKind.ios, .tvos] {
      let model = make([pad(), pad("pad-1", name: "Siri Remote", isMenuRemote: true)], platform: platform)
      XCTAssertEqual(model.focusableIDs, model.allItems.map(\.id), "\(platform)")
      XCTAssertEqual(Set(model.allItems.map(\.id)).count, model.allItems.count, "row ids are unique")
      XCTAssertEqual(make([], platform: platform).focusableIDs, make([], platform: platform).allItems.map(\.id))
    }
  }

  func test_controllerRows() {
    let source = pad()
    XCTAssertEqual(ids(make([source]), section: "motion-pad-0"), [
      MotionTestModelBuilder.poseRowID(source), MotionTestModelBuilder.turnRowID(source),
      MotionTestModelBuilder.remoteAccelerationRowID(source), MotionTestModelBuilder.remoteGyroRowID(source),
      MotionTestModelBuilder.rawAccelerationRowID(source), MotionTestModelBuilder.rawRotationRowID(source),
      MotionTestModelBuilder.capabilitiesRowID(source), MotionTestModelBuilder.activationRowID(source),
    ])
  }

  /// Only a gamepad's section explains the Motion Axes switches: a remote has none.
  func test_onlyControllerSectionsCarryTheMotionAxesFooter() {
    let model = make([pad(), pad("pad-1", name: "Siri Remote", isMenuRemote: true)], platform: .tvos)
    XCTAssertNotNil(model.sections.first { $0.id == "motion-pad-0" }?.footer)
    XCTAssertNil(model.sections.first { $0.id == "motion-pad-1" }?.footer)
  }

  // MARK: The lines a tester reads

  /// The check the screen exists for: a pad lying flat says so.
  func test_aPadLyingFlat_readsFlatFaceUp() {
    let source = pad()
    let model = make([source])
    XCTAssertEqual(model.item(id: MotionTestModelBuilder.poseRowID(source))?.title, WiiRemotePose.flatFaceUp.title)
    XCTAssertEqual(model.item(id: MotionTestModelBuilder.poseRowID(source))?.subtitle, "Pitch +0° · Roll +0°")
    XCTAssertEqual(model.item(id: MotionTestModelBuilder.turnRowID(source))?.title, WiiRemoteTurn.still.title)
    XCTAssertEqual(
      model.item(id: MotionTestModelBuilder.remoteAccelerationRowID(source))?.subtitle, "Left +0.00 · Back +0.00 · Up +9.81 m/s²")
    XCTAssertEqual(model.item(id: MotionTestModelBuilder.rawAccelerationRowID(source))?.subtitle, "X +0.00 · Y +0.00 · Z -1.00 g")
  }

  func test_poseLine_followsThePad() {
    let poses: [(SIMD3<Double>, WiiRemotePose, String)] = [
      (SIMD3(0, 0, 1), .flatFaceDown, "Pitch +0° · Roll +180°"),
      (SIMD3(0, -1, 0), .pointingAtCeiling, "Pitch +90° · Roll +0°"),
      (SIMD3(0, 1, 0), .pointingAtFloor, "Pitch -90° · Roll +0°"),
      (SIMD3(1, 0, 0), .rightSideDown, "Pitch +0° · Roll +90°"),
      (SIMD3(-1, 0, 0), .leftSideDown, "Pitch +0° · Roll -90°"),
    ]
    for (acceleration, pose, tilt) in poses {
      let source = pad(acceleration: acceleration)
      let row = make([source]).item(id: MotionTestModelBuilder.poseRowID(source))
      XCTAssertEqual(row?.title, pose.title, "pad \(acceleration)")
      XCTAssertEqual(row?.subtitle, tilt, "pad \(acceleration)")
    }
  }

  /// A swing says nothing about tilt: no angles.
  func test_aMovingPad_showsNoTilt() {
    let source = pad(acceleration: SIMD3(0, 0, -2.5))
    let row = make([source]).item(id: MotionTestModelBuilder.poseRowID(source))
    XCTAssertEqual(row?.title, WiiRemotePose.moving.title)
    XCTAssertNil(row?.subtitle)
  }

  /// Lifting the nose is +x on GCMotion and Pitch Up on the remote, whose pitch axis reads the
  /// other way (Pitch Down - Pitch Up).
  func test_turnLine_andTheNumbersBehindIt() {
    let source = pad(rotationRate: SIMD3(1.5, 0, 0.25))
    let model = make([source])
    XCTAssertEqual(model.item(id: MotionTestModelBuilder.turnRowID(source))?.title, WiiRemoteTurn.pitchUp.title)
    XCTAssertEqual(
      model.item(id: MotionTestModelBuilder.remoteGyroRowID(source))?.subtitle,
      "Pitch Down -1.50 · Roll Left +0.00 · Yaw Left +0.25 rad/s")
    XCTAssertEqual(model.item(id: MotionTestModelBuilder.rawRotationRowID(source))?.subtitle, "X +1.50 · Y +0.00 · Z +0.25 rad/s")
  }

  /// `hasRotationRate` false: the core adds no gyro inputs, so the rates it reports (zeros) are not shown.
  func test_aPadWithoutAGyroscope_saysSo() {
    let source = pad(rotationRate: SIMD3(3, 3, 3), flags: flags(rotationRate: false))
    let model = make([source])
    XCTAssertEqual(model.item(id: MotionTestModelBuilder.turnRowID(source))?.title, L("No gyroscope"))
    XCTAssertEqual(model.item(id: MotionTestModelBuilder.remoteGyroRowID(source))?.subtitle, L("Not reported"))
    XCTAssertEqual(model.item(id: MotionTestModelBuilder.rawRotationRowID(source))?.subtitle, L("Not reported"))
  }

  // MARK: Capability flags

  func test_capabilityFlags() {
    let source = pad(flags: flags(rotationRate: true, gravityAndUser: true, attitude: false))
    XCTAssertEqual(
      make([source]).item(id: MotionTestModelBuilder.capabilitiesRowID(source))?.subtitle,
      "Rotation rate: Yes · Gravity and user acceleration: Yes · Attitude: No")
  }

  func test_sensorActivation() {
    func text(manual: Bool, active: Bool) -> String? {
      let source = pad(flags: flags(manual: manual, active: active))
      return make([source]).item(id: MotionTestModelBuilder.activationRowID(source))?.subtitle
    }
    XCTAssertEqual(text(manual: false, active: false), L("Automatic"))
    XCTAssertEqual(text(manual: true, active: true), L("Manual, switched on"))
    XCTAssertEqual(text(manual: true, active: false), L("Manual, switched off"))
  }

  // MARK: This device (iOS)

  func test_device_withoutSensors_saysSo() {
    let model = make([pad()])
    XCTAssertEqual(ids(model, section: MotionTestModelBuilder.deviceSectionID), [MotionTestModelBuilder.deviceUnavailableRowID])
    XCTAssertEqual(model.item(id: MotionTestModelBuilder.deviceUnavailableRowID)?.title, L("This device has no motion sensors"))
  }

  func test_device_beforeItsFirstSample_isWaiting() {
    let model = make([], deviceAvailable: true)
    XCTAssertEqual(model.item(id: MotionTestModelBuilder.deviceUnavailableRowID)?.title, L("Waiting for the motion sensors…"))
  }

  /// The device has the readings but no capability flags, and its own footer about the grip.
  func test_device_rows() {
    let device = MotionTestSource(
      id: "device", name: "", kind: .device, acceleration: SIMD3(0, -1, 0), rotationRate: nil, flags: nil,
      remote: WiiRemoteMotion(acceleration: SIMD3(0, 0, WiiRemoteMotionMapping.standardGravity), angularVelocity: nil))
    let model = make([pad()], device: device, deviceAvailable: true)
    XCTAssertEqual(ids(model, section: MotionTestModelBuilder.deviceSectionID), [
      MotionTestModelBuilder.poseRowID(device), MotionTestModelBuilder.turnRowID(device),
      MotionTestModelBuilder.remoteAccelerationRowID(device), MotionTestModelBuilder.remoteGyroRowID(device),
      MotionTestModelBuilder.rawAccelerationRowID(device), MotionTestModelBuilder.rawRotationRowID(device),
    ])
    XCTAssertEqual(model.item(id: MotionTestModelBuilder.poseRowID(device))?.title, WiiRemotePose.flatFaceUp.title)
    let section = model.sections.first { $0.id == MotionTestModelBuilder.deviceSectionID }
    XCTAssertNotNil(section?.footer)
    XCTAssertNotEqual(section?.footer, model.sections.first { $0.id == "motion-pad-0" }?.footer)
  }

  // MARK: Number formatting

  /// A resting axis must not flicker between "+0.00" and "-0.00".
  func test_signed_hasNoNegativeZero() {
    XCTAssertEqual(MotionTestModelBuilder.signed(-0.001), "+0.00")
    XCTAssertEqual(MotionTestModelBuilder.signed(0.004), "+0.00")
    XCTAssertEqual(MotionTestModelBuilder.signed(-0.006), "-0.01")
    XCTAssertEqual(MotionTestModelBuilder.signed(9.80665), "+9.81")
    XCTAssertEqual(MotionTestModelBuilder.signed(-0.4, decimals: 0), "+0")
    XCTAssertEqual(MotionTestModelBuilder.signed(-89.6, decimals: 0), "-90")
  }
}
