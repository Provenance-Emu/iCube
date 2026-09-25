// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class RemapModelTests: XCTestCase {

  // MARK: Groups

  /// Pins the raw values to the C++ enums (`PadGroup` in GCPadEmu.h,
  /// `WiimoteEmu::WiimoteGroup` in WiimoteEmu.h). The legacy table had
  /// D-Pad = 1, which is MainStick.
  func test_gamecubeGroupIds_matchPadGroupEnum() {
    let ids = Dictionary(uniqueKeysWithValues: RemapGroup.gamecube.map { ($0.title, $0.id) })
    XCTAssertEqual(ids["Buttons"], 0)
    XCTAssertEqual(ids["Control Stick"], 1)
    XCTAssertEqual(ids["C-Stick"], 2)
    XCTAssertEqual(ids["D-Pad"], 3)
    XCTAssertEqual(ids["Triggers"], 4)
    XCTAssertEqual(ids["Rumble"], 5)
    XCTAssertEqual(ids["Options"], 7)
    XCTAssertEqual(RemapGroup.gamecube.count, 7)
  }

  func test_wiiGroupIds_matchWiimoteGroupEnum() {
    let ids = Dictionary(uniqueKeysWithValues: RemapGroup.wii.map { ($0.title, $0.id) })
    XCTAssertEqual(ids["Buttons"], 0)
    XCTAssertEqual(ids["D-Pad"], 1)
    XCTAssertEqual(ids["Shake"], 2)
    XCTAssertEqual(ids["IR"], 3)
    XCTAssertEqual(ids["Tilt"], 4)
    XCTAssertEqual(ids["Swing"], 5)
    XCTAssertEqual(ids["Rumble"], 6)
    XCTAssertEqual(ids["Options"], 8)
    XCTAssertNil(ids["Extension"], "Attachments is the header's Extension control, not a group")
  }

  func test_groupIds_areUniquePerSystem() {
    for system in [RemapSystem.gamecube, .wii] {
      let ids = RemapGroup.groups(for: system).map(\.id)
      XCTAssertEqual(Set(ids).count, ids.count)
    }
  }

  // MARK: Expressions

  func test_expression_isBacktickQuotedInputName() {
    XCTAssertEqual(RemapExpression.expression(forInputName: "Button A"), "`Button A`")
    XCTAssertEqual(RemapExpression.expression(forInputName: "L Stick Y+"), "`L Stick Y+`")
  }

  func test_motionInputs_areNotCapturable() {
    XCTAssertFalse(RemapExpression.isCapturable(inputName: "Accel Up"))
    XCTAssertFalse(RemapExpression.isCapturable(inputName: "Gyro Pitch Up"))
    XCTAssertTrue(RemapExpression.isCapturable(inputName: "Button A"))
    XCTAssertTrue(RemapExpression.isCapturable(inputName: "R Trigger"))
  }

  // MARK: Capture machine

  private let cfg = RemapCaptureMachine.Config(threshold: 0.35, restEpsilon: 0.15, holdPolls: 3, timeoutPolls: 10)

  private func machine(baseline: [Float], capturable: [Bool]? = nil) -> RemapCaptureMachine {
    RemapCaptureMachine(baseline: baseline,
                        capturable: capturable ?? Array(repeating: true, count: baseline.count),
                        config: cfg)
  }

  func test_touchArm_nothingHeld_passesGateOnFirstPoll() {
    var m = machine(baseline: [0, 0, 0])
    XCTAssertEqual(m.phase, .waitingForRelease)
    XCTAssertNil(m.poll([0, 0, 0]))
    XCTAssertEqual(m.phase, .listening)
  }

  /// The A press that armed the row is held at arm time and must not become
  /// the binding; the first press AFTER release does.
  func test_controllerArm_heldButtonIsNotCaptured_untilReleasedAndPressedAgain() {
    var m = machine(baseline: [1, 0, 0]) // input 0 = the A that activated the row
    XCTAssertNil(m.poll([1, 0, 0]))
    XCTAssertNil(m.poll([1, 0, 0]))
    XCTAssertEqual(m.phase, .waitingForRelease)
    XCTAssertNil(m.poll([0, 0, 0])) // released -> listening, rest re-baselined
    XCTAssertEqual(m.phase, .listening)
    XCTAssertNil(m.poll([1, 0, 0]))
    XCTAssertNil(m.poll([1, 0, 0]))
    XCTAssertEqual(m.poll([1, 0, 0]), .captured(inputIndex: 0))
    XCTAssertEqual(m.phase, .finished)
    XCTAssertNil(m.poll([1, 0, 0]), "a finished machine reports nothing further")
  }

  func test_debounce_requiresConsecutivePolls() {
    var m = machine(baseline: [0, 0])
    XCTAssertNil(m.poll([0, 0]))
    XCTAssertNil(m.poll([1, 0]))
    XCTAssertNil(m.poll([0, 0])) // bounce resets the run
    XCTAssertNil(m.poll([1, 0]))
    XCTAssertNil(m.poll([1, 0]))
    XCTAssertEqual(m.poll([1, 0]), .captured(inputIndex: 0))
  }

  /// Trigger drift / stick centering error: the resting value is above zero
  /// but below threshold; it must be neither a gate blocker nor a candidate.
  func test_analogDrift_isAbsorbedByRestBaseline() {
    var m = machine(baseline: [0.12, 0])
    XCTAssertNil(m.poll([0.12, 0]))
    XCTAssertEqual(m.phase, .listening)
    for _ in 0 ..< 5 { XCTAssertNil(m.poll([0.3, 0])) } // wobble under threshold relative to rest
    XCTAssertNil(m.poll([0.9, 0]))
    XCTAssertNil(m.poll([0.9, 0]))
    XCTAssertEqual(m.poll([0.9, 0]), .captured(inputIndex: 0))
  }

  func test_largestRiseWins_whenTwoInputsCross() {
    var m = machine(baseline: [0, 0])
    XCTAssertNil(m.poll([0, 0]))
    for _ in 0 ..< 2 { XCTAssertNil(m.poll([0.5, 0.9])) }
    XCTAssertEqual(m.poll([0.5, 0.9]), .captured(inputIndex: 1))
  }

  func test_nonCapturableInput_isIgnored() {
    var m = machine(baseline: [0, 0], capturable: [false, true])
    XCTAssertNil(m.poll([0, 0]))
    for _ in 0 ..< 9 { XCTAssertNil(m.poll([1, 0])) }
    XCTAssertEqual(m.poll([1, 0]), .timedOut)
  }

  func test_timeout_countsListeningPollsOnly() {
    var m = machine(baseline: [1])
    for _ in 0 ..< 20 { XCTAssertNil(m.poll([1])) } // still waiting for release, no timeout
    XCTAssertEqual(m.phase, .waitingForRelease)
    XCTAssertNil(m.poll([0]))
    for _ in 0 ..< 9 { XCTAssertNil(m.poll([0])) }
    XCTAssertEqual(m.poll([0]), .timedOut)
  }

  func test_deviceVanished_emptyVectorTimesOutInsteadOfCrashing() {
    var m = machine(baseline: [1, 0])
    XCTAssertNil(m.poll([])) // held input reads as released
    XCTAssertEqual(m.phase, .listening)
    for _ in 0 ..< 9 { XCTAssertNil(m.poll([])) }
    XCTAssertEqual(m.poll([]), .timedOut)
  }

  // MARK: Controller navigation

  private var navCfg: RemapControllerNav.Config {
    RemapControllerNav.Config(initialRepeatDelay: 0.4, repeatInterval: 0.08, stickEngage: 0.6, stickRelease: 0.3)
  }

  func test_dpad_movesOnceOnPress_thenRepeatsAfterInitialDelay() {
    var nav = RemapControllerNav(config: navCfg)
    let down = RemapControllerNav.Input(down: true)
    XCTAssertEqual(nav.update(down, at: 0), [.move(1)])
    XCTAssertEqual(nav.update(down, at: 0.1), [])
    XCTAssertEqual(nav.update(down, at: 0.39), [])
    XCTAssertEqual(nav.update(down, at: 0.4), [.move(1)])
    XCTAssertEqual(nav.update(down, at: 0.45), [])
    XCTAssertEqual(nav.update(down, at: 0.5), [.move(1)])
    XCTAssertEqual(nav.update(.init(), at: 0.55), [])
    XCTAssertEqual(nav.update(down, at: 0.6), [.move(1)], "release then press is a new edge")
  }

  func test_stick_hasHysteresis() {
    var nav = RemapControllerNav(config: navCfg)
    XCTAssertEqual(nav.update(.init(stickY: 0.5), at: 0), [], "below engage: nothing")
    XCTAssertEqual(nav.update(.init(stickY: 0.7), at: 0.01), [.move(-1)])
    XCTAssertEqual(nav.update(.init(stickY: 0.4), at: 0.02), [], "still engaged, no new edge")
    XCTAssertEqual(nav.update(.init(stickY: 0.7), at: 0.03), [], "never released: no new edge")
    XCTAssertEqual(nav.update(.init(stickY: 0.2), at: 0.04), [], "released")
    XCTAssertEqual(nav.update(.init(stickY: -0.7), at: 0.05), [.move(1)])
  }

  func test_activate_firesOncePerPress() {
    var nav = RemapControllerNav(config: navCfg)
    XCTAssertEqual(nav.update(.init(a: true), at: 0), [.activate])
    XCTAssertEqual(nav.update(.init(a: true), at: 0.1), [])
    XCTAssertEqual(nav.update(.init(a: true), at: 5), [], "held forever never re-fires")
    XCTAssertEqual(nav.update(.init(a: false), at: 5.1), [])
    XCTAssertEqual(nav.update(.init(a: true), at: 5.2), [.activate])
  }

  func test_back_firesOncePerPress() {
    var nav = RemapControllerNav(config: navCfg)
    XCTAssertEqual(nav.update(.init(b: true), at: 0), [.back])
    XCTAssertEqual(nav.update(.init(b: true), at: 0.1), [])
  }

  /// After a capture ends, the just-captured A / stick push is still held and
  /// must not activate or move.
  func test_resync_adoptsHeldStateWithoutEmitting() {
    var nav = RemapControllerNav(config: navCfg)
    let held = RemapControllerNav.Input(stickY: 1, a: true)
    nav.resync(held, at: 10)
    XCTAssertEqual(nav.update(held, at: 10.01), [])
    XCTAssertEqual(nav.update(held, at: 11), [], "no repeat for a hold adopted by resync")
    XCTAssertEqual(nav.update(.init(), at: 11.1), [])
    XCTAssertEqual(nav.update(held, at: 11.2), [.move(-1), .activate])
  }
}
