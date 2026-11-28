// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class TopBarLayoutTests: XCTestCase {
  func testDirectDestinationsHaveNoMoreMenuDetour() {
    XCTAssertEqual(TopBarControl.menu.directDestination, .pauseMenu)
    XCTAssertEqual(TopBarControl.saves.directDestination, .saveStates)
    XCTAssertEqual(TopBarControl.shaders.directDestination, .shaders)
    XCTAssertEqual(TopBarControl.exit.directDestination, .exitConfirm, "Exit goes to the confirmation, never straight out")
    XCTAssertNil(TopBarControl.save.directDestination, "Saving has a separate action, never a navigation side effect")
    XCTAssertNil(TopBarControl.load.directDestination, "Loading has a separate action, never a navigation side effect")
  }

  func testPortraitUsesSingleCompactActionSetOnPhoneAndPad() {
    for size in [CGSize(width: 320, height: 568), CGSize(width: 393, height: 852), CGSize(width: 1024, height: 1366)] {
      XCTAssertFalse(TopBarLayout.usesWideRow(width: size.width, height: size.height, accessibilityType: false))
    }
    XCTAssertEqual(TopBarLayout.compactControls, [.menu, .save, .load, .saves, .display, .options, .exit])
  }

  func testWideLandscapeAndSplitWindowUseAvailableGeometry() {
    XCTAssertTrue(TopBarLayout.usesWideRow(width: 1366, height: 1024, accessibilityType: false))
    XCTAssertFalse(TopBarLayout.usesWideRow(width: 900, height: 600, accessibilityType: false))
    XCTAssertEqual(TopBarLayout.wideControls, [.menu, .save, .load, .saves, .fastForward, .audio, .controller, .display, .shaders, .exit])
  }

  func testMenuLeadsAndExitEndsBothRows() {
    for row in [TopBarLayout.compactControls, TopBarLayout.wideControls] {
      XCTAssertEqual(row.first, .menu)
      XCTAssertEqual(row.last, .exit)
      XCTAssertTrue(row.contains(.display), "Display is on the bar in every layout")
      XCTAssertEqual(Set(row).count, row.count)
    }
  }

  func testStandardToolbarHeightAndMinimumTargets() {
    XCTAssertLessThanOrEqual(TopBarLayout.standardHeight, 80)
    XCTAssertGreaterThanOrEqual(TopBarLayout.minimumTarget, 44)
    XCTAssertGreaterThanOrEqual(TopBarLayout.controlHeight, TopBarLayout.minimumTarget)
    XCTAssertLessThanOrEqual(CGFloat(TopBarLayout.compactControls.count) * TopBarLayout.minimumTarget + 2 * TopBarLayout.horizontalPadding, 375,
                             "the compact row fits a 375 pt phone at the minimum target")
  }

  func testAccessibilityTypeKeepsPrimaryActionsInAdaptiveLayout() {
    XCTAssertFalse(TopBarLayout.usesWideRow(width: 1366, height: 1024, accessibilityType: true))
    XCTAssertEqual(Array(TopBarLayout.compactControls.prefix(4)), [.menu, .save, .load, .saves])
  }

  // MARK: - Long press

  func testEveryLongPressHasANameAndOpensSomethingTheTapDoesNot() {
    for control in TopBarControl.allCases {
      XCTAssertEqual(control.longPress == nil, control.longPressTitle == nil, "\(control): a hold and its VoiceOver name go together")
      if case .destination(let held)? = control.longPress {
        XCTAssertNotEqual(held, control.directDestination, "\(control): the hold repeats the tap")
      }
    }
    XCTAssertEqual(TopBarControl.fastForward.longPress, .popover(.speed))
    XCTAssertEqual(TopBarControl.audio.longPress, .toggleMute)
    XCTAssertEqual(TopBarControl.shaders.longPress, .destination(.shaderParameters))
    XCTAssertEqual(TopBarControl.menu.longPress, .popover(.options))
    XCTAssertNil(TopBarControl.exit.longPress, "Exit has one meaning")
  }

  // MARK: - Captions

  func testCaptionsShowWhatEachButtonIsSetTo() {
    var values = TopBarValues()
    XCTAssertNil(values.caption(for: .save), "history mode has no slot to show")
    XCTAssertEqual(values.caption(for: .fastForward), L("Off"))
    XCTAssertEqual(values.caption(for: .audio), "100 %")
    XCTAssertEqual(values.caption(for: .display), L("Auto"))
    XCTAssertEqual(values.caption(for: .shaders), L("Off"))
    XCTAssertNil(values.caption(for: .controller))

    values.quickSlot = 3
    values.fastForwardPercent = 200
    values.volume = 40
    values.controllerName = "DualSense"
    values.aspectRaw = 1
    values.shaderName = "crt-royale"
    XCTAssertEqual(values.caption(for: .save), String(format: L("Slot %d"), 3))
    XCTAssertEqual(values.caption(for: .load), values.caption(for: .save))
    XCTAssertEqual(values.caption(for: .fastForward), "2x")
    XCTAssertEqual(values.caption(for: .audio), "40 %")
    XCTAssertEqual(values.caption(for: .controller), "DualSense")
    XCTAssertEqual(values.caption(for: .display), "16:9")
    XCTAssertEqual(values.caption(for: .shaders), "crt-royale")
    for control in [TopBarControl.menu, .saves, .options, .exit] {
      XCTAssertNil(values.caption(for: control))
    }
  }

  func testAudioCaptionSaysMutedAtZeroOrWhenMuted() {
    XCTAssertEqual(TopBarValues(volume: 80, isMuted: true).audioTitle, L("Muted"))
    XCTAssertEqual(TopBarValues(volume: 0, isMuted: false).audioTitle, L("Muted"))
  }

  func testSpeedTitles() {
    XCTAssertEqual(TopBarValues.speedTitle(percent: nil), L("Off"))
    XCTAssertEqual(TopBarValues.speedTitle(percent: 0), L("Max"))
    XCTAssertEqual(TopBarValues.speedTitle(percent: 300), "3x")
    XCTAssertEqual(TopBarValues.speedTitle(percent: 150), "1.5x")
    XCTAssertEqual(TopBarValues.speedOptions.map(\.title), TopBarValues.speedOptions.map { TopBarValues.speedTitle(percent: $0.percent) })
  }

  func testSpeedOptionsAreThePauseMenusSpeeds() {
    let bar = TopBarValues.speedOptions.map { $0.percent ?? -1 }
    let pause = PauseMenuModelBuilder.fastForwardOptions.compactMap { $0.1 as? Int }
    XCTAssertEqual(bar, pause)
  }

  func testAspectOptionsMatchTheSettingsEnum() {
    XCTAssertEqual(Set(TopBarValues.aspectOptions.map(\.raw)), Set(AspectRatio.allCases.map(\.aspectRaw)))
    XCTAssertEqual(TopBarValues.aspectTitle(raw: 99), L("Auto"), "an unknown value reads as Dolphin treats it")
  }
}
