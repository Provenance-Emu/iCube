// DolphiniOSTests/PauseFastForwardStateTests.swift
import XCTest
@testable import iCube

final class PauseFastForwardStateTests: XCTestCase {
  private let options = PauseMenuModelBuilder.fastForwardOptions

  func test_cyclingFromOff_visitsEverySpeedThenOff() {
    var state = PauseFastForwardState(isEnabled: false, percent: 300)
    var titles: [String] = []
    var effects: [PauseFastForwardState.Effect] = []
    for _ in 0 ..< options.count {
      let next = MenuItemRole.cycled(options: options, current: state.selection, step: 1)!
      effects.append(state.select(next))
      titles.append(MenuItemRole.selectedTitle(options: options, current: state.selection) ?? "—")
    }
    XCTAssertEqual(titles, ["2x", "3x", "4x", "8x", "Unlimited", "Off"])
    XCTAssertEqual(effects, [.setSpeed(200), .setSpeed(300), .setSpeed(400), .setSpeed(800), .setSpeed(0), .turnOff])
  }

  /// An off-ladder value renders as a dash and, like every cycle tile (`MenuModelTests.test_cycled_unknownCurrent_landsOnFirstOption`),
  /// the next press lands on the first option: Off, then 2x. Off stays reachable because the
  /// tile's long-press picker offers it explicitly.
  func test_storedPercentOffTheLadder_showsDash_andCyclesOffThenTwoX() {
    var state = PauseFastForwardState(isEnabled: true, percent: 150)
    XCTAssertNil(MenuItemRole.selectedTitle(options: options, current: state.selection))
    let first = MenuItemRole.cycled(options: options, current: state.selection, step: 1)!
    XCTAssertEqual(state.select(first), .turnOff)
    XCTAssertEqual(state.percent, 150)
    let second = MenuItemRole.cycled(options: options, current: state.selection, step: 1)!
    XCTAssertEqual(state.select(second), .setSpeed(200))
    XCTAssertEqual(state.percent, 200)
  }

  func test_selectOff_keepsLastPercentForNextTime() {
    var state = PauseFastForwardState(isEnabled: true, percent: 400)
    XCTAssertEqual(state.select(PauseMenuModelBuilder.fastForwardOff), .turnOff)
    XCTAssertFalse(state.isEnabled)
    XCTAssertEqual(state.percent, 400)
  }
}
