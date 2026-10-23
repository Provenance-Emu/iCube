// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// `NoControllerNotice` (design A4, plan call 2): when the tvOS "No controller connected" notice
/// shows, which devices count as a gameplay pad, and which launches never show it.
final class NoControllerNoticeTests: XCTestCase {

  private func inputs(
    secondsRunning: TimeInterval? = 3, alreadyShown: Bool = false, pad: Bool = false, overlay: Bool = false,
    harness: Bool = false
  ) -> NoControllerNotice.Inputs {
    NoControllerNotice.Inputs(
      secondsRunning: secondsRunning, alreadyShown: alreadyShown, gameplayPadConnected: pad, anotherOverlayIsUp: overlay,
      isHarnessLaunch: harness)
  }

  func test_showsThreeSecondsIn_withNoPad() {
    XCTAssertTrue(NoControllerNotice.shouldShow(inputs()))
    XCTAssertTrue(NoControllerNotice.shouldShow(inputs(secondsRunning: 40)))
  }

  /// A pad that connects during the boot must not trip it, so nothing before the delay.
  func test_waitsForTheDelay_andForTheGameToRun() {
    XCTAssertFalse(NoControllerNotice.shouldShow(inputs(secondsRunning: 2.9)))
    XCTAssertFalse(NoControllerNotice.shouldShow(inputs(secondsRunning: nil)))
  }

  func test_neverWithAPad_onceOnly_notOverAnotherOverlay_notInAHarness() {
    XCTAssertFalse(NoControllerNotice.shouldShow(inputs(pad: true)))
    XCTAssertFalse(NoControllerNotice.shouldShow(inputs(alreadyShown: true)))
    XCTAssertFalse(NoControllerNotice.shouldShow(inputs(overlay: true)))
    XCTAssertFalse(NoControllerNotice.shouldShow(inputs(harness: true)))
  }

  /// The touchscreen (`iOS/…`) is not a pad; the Siri Remote never reaches `connectedQualifiers`.
  func test_gameplayPad_isAnythingButTheAppsOwnDevices() {
    XCTAssertFalse(NoControllerNotice.hasGameplayPad(connectedQualifiers: []))
    XCTAssertFalse(NoControllerNotice.hasGameplayPad(connectedQualifiers: ["iOS/0/Touchscreen", "iOS/4/Touchscreen"]))
    XCTAssertTrue(NoControllerNotice.hasGameplayPad(connectedQualifiers: ["iOS/4/Touchscreen", "MFi/0/Xbox Wireless Controller"]))
    XCTAssertTrue(NoControllerNotice.hasGameplayPad(connectedQualifiers: ["DSUClient/0/Pad C"]))
  }

  func test_harnessLaunches() {
    XCTAssertTrue(NoControllerNotice.isHarnessLaunch(arguments: ["iCube", "-ICubePausePreview"], screenshotMode: false))
    XCTAssertTrue(NoControllerNotice.isHarnessLaunch(arguments: ["iCube", "-ICubeLivePerformancePreview"], screenshotMode: false))
    XCTAssertTrue(NoControllerNotice.isHarnessLaunch(arguments: ["iCube", "-SCREENSHOT_MODE", "1"], screenshotMode: true))
    XCTAssertTrue(NoControllerNotice.isHarnessLaunch(arguments: ["iCube"], screenshotMode: true))
    XCTAssertFalse(NoControllerNotice.isHarnessLaunch(arguments: ["iCube", "-ICubeAppearance", "dark"], screenshotMode: false))
  }

  /// Continue first (a stray press plays on), then the phone, then Controllers.
  func test_model_continueThenPhoneThenControllers() {
    var calls: [String] = []
    let model = NoControllerNotice.model(
      phoneName: nil, onContinue: { calls.append("continue") }, onControllers: { calls.append("controllers") },
      onUsePhone: { calls.append("phone") })
    let items = model.sections.flatMap(\.items)
    XCTAssertEqual(items.map(\.id), ["no-controller-continue", "use-phone", "no-controller-controllers"])
    for item in items {
      guard case .action(let action) = item.role else { return XCTFail("action rows") }
      action()
    }
    XCTAssertEqual(calls, ["continue", "phone", "controllers"])
  }

  func test_notice_offersTheAdvertisingPhoneByName() {
    let model = NoControllerNotice.model(phoneName: "Joe's iPhone", onContinue: {}, onControllers: {}, onUsePhone: {})
    XCTAssertEqual(model.item(id: "use-phone")?.title, "Use Joe's iPhone")
    XCTAssertEqual(model.sections.flatMap(\.items).map(\.title), ["Continue", "Use Joe's iPhone", "Controllers"])
  }

  func test_notice_explainsHowWhenNoPhoneIsAdvertising() {
    let model = NoControllerNotice.model(phoneName: nil, onContinue: {}, onControllers: {}, onUsePhone: {})
    XCTAssertEqual(model.item(id: "use-phone")?.title, "Use Your iPhone")
    XCTAssertEqual(NoControllerNotice.usePhoneHelpMessage, "Open iCube on your iPhone and tap Play on Apple TV.")
  }

  /// The explanation panel has one row, which goes back to the notice.
  func test_usePhoneHelpModel_isOneBackRow() {
    var backs = 0
    let model = NoControllerNotice.usePhoneHelpModel(onBack: { backs += 1 })
    let items = model.sections.flatMap(\.items)
    XCTAssertEqual(items.map(\.id), ["use-phone-help-back"])
    XCTAssertEqual(items.map(\.title), ["Back"])
    guard case .action(let action) = items[0].role else { return XCTFail("action row") }
    action()
    XCTAssertEqual(backs, 1)
  }
}
