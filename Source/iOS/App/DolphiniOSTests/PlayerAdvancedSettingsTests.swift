// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

/// The stepped values a numeric setting's picker offers (a slider cannot be reached by a pad on iOS
/// or focused on tvOS), their labels, and which groups Advanced lists.
final class PlayerAdvancedSettingsTests: XCTestCase {

  private func setting(
    min: Double, max: Double, value: Double, defaultValue: Double, isInteger: Bool = false, suffix: String = "%"
  ) -> NumericSettingState {
    NumericSettingState(
      owner: .gcPad, groupId: 1, index: 0, name: "Dead Zone", suffix: suffix, isToggle: false, isInteger: isInteger,
      value: value, minimum: min, maximum: max, defaultValue: defaultValue, isExpression: false)
  }

  /// `AddDeadzoneSetting` (ControlGroup.cpp): 0...50 %.
  func test_deadZone_stepsOfFive() {
    let values = NumericSettingSteps.values(for: setting(min: 0, max: 50, value: 0, defaultValue: 0))
    XCTAssertEqual(values, [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50])
  }

  /// Gate Size (AnalogStick.cpp:89-97): 0.01...100 %, default the stick's gate radius.
  func test_gateSize_includesTheEndsTheDefaultAndTheCurrentValue() {
    let values = NumericSettingSteps.values(for: setting(min: 0.01, max: 100, value: 64.2, defaultValue: 79.37125))
    XCTAssertEqual(values.first, 0.01)
    XCTAssertEqual(values.last, 100)
    XCTAssertTrue(values.contains(79.37125), "the default is always offered")
    XCTAssertTrue(values.contains(64.2), "the current value is always offered, so the picker shows a selection")
    XCTAssertTrue(values.contains(50))
    XCTAssertEqual(values, values.sorted())
  }

  func test_integerSettings_stepByWholeNumbers() {
    XCTAssertEqual(NumericSettingSteps.values(for: setting(min: 0, max: 3, value: 1, defaultValue: 1, isInteger: true)), [0, 1, 2, 3])
  }

  func test_nearest() {
    XCTAssertEqual(NumericSettingSteps.nearest(to: 12.4, in: [0, 5, 10, 15]), 10)
    XCTAssertEqual(NumericSettingSteps.nearest(to: 13, in: [0, 5, 10, 15]), 15)
  }

  func test_labels() {
    XCTAssertEqual(NumericSettingSteps.label(25, suffix: "%"), "25%")
    XCTAssertEqual(NumericSettingSteps.label(79.37125, suffix: "%"), "79.37%")
    XCTAssertEqual(NumericSettingSteps.label(45, suffix: "°"), "45°")
    XCTAssertEqual(NumericSettingSteps.label(10, suffix: "cm"), "10 cm")
    XCTAssertEqual(NumericSettingSteps.label(0.5, suffix: ""), "0.5")
    XCTAssertEqual(NumericSettingSteps.label(0, suffix: ""), "0")
  }

  func test_advancedGroups_gameCube() {
    XCTAssertEqual(
      AdvancedSettingGroups.entries(for: .gamecube, attachment: 0).map(\.groupId), [1, 2, 4])
  }

  func test_advancedGroups_wiiFollowTheExtension() {
    func keys(_ attachment: Int) -> [String] {
      AdvancedSettingGroups.entries(for: .wii, attachment: attachment).map { "\($0.owner)-\($0.groupId)" }
    }
    XCTAssertEqual(keys(0), ["wiimote-3", "wiimote-12"])
    XCTAssertEqual(keys(1), ["wiimote-3", "wiimote-12", "nunchuk-1"])
    XCTAssertEqual(keys(2), ["wiimote-3", "wiimote-12", "classic-3", "classic-4", "classic-1"])
  }

  /// `WiimoteEmu::WiimoteGroup`: …, IMUAccelerometer = 10, IMUGyroscope = 11, IMUPoint = 12.
  func test_imuPointIsGroupTwelve() {
    XCTAssertEqual(AdvancedSettingGroups.imuPointGroup, 12)
  }
}
