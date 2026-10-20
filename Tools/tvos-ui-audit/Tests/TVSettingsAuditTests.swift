// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

final class TVSettingsAuditTests: XCTestCase {
  override func tearDown() {
    XCUIApplication(bundleIdentifier: "com.joemattiello.iCube-debug").terminate()
    super.tearDown()
  }

  private func launch(_ args: [String] = []) -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "com.joemattiello.iCube-debug")
    app.launchArguments = ["-SCREENSHOT_MODE", "1", "-onboarding_seen_v1", "YES", "-ICubeAppearance", "dark", "-library_platform_filter", "all"] + args
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    return app
  }

  private func focus(_ button: XCUIElement, direction: XCUIRemote.Button = .down, limit: Int = 20) -> Bool {
    guard button.waitForExistence(timeout: 20) else {
      XCTFail("Missing focus target")
      return false
    }
    for _ in 0..<limit {
      if button.hasFocus { return true }
      XCUIRemote.shared.press(direction)
    }
    XCTFail("Could not focus \(button.label)")
    return false
  }

  func testLibraryPlatformsAndContentFocus() {
    let app = launch()
    guard focus(app.buttons["Wii"]) else { return }
    XCUIRemote.shared.press(.select)
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Wii ·")).firstMatch.waitForExistence(timeout: 5))
    record(app, "library-wii")
    guard focus(app.buttons["GameCube"], direction: .up) else { return }
    XCUIRemote.shared.press(.select)
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "GameCube ·")).firstMatch.waitForExistence(timeout: 5))
    guard focus(app.buttons["All Games"], direction: .up) else { return }
    XCUIRemote.shared.press(.select)
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "All Games ·")).firstMatch.waitForExistence(timeout: 5))
    XCUIRemote.shared.press(.right)
    record(app, "library-content-after-right")
    // Names must survive the icon-only state for VoiceOver as well as automated navigation.
    for title in ["Search", "My Library", "All Games", "GameCube", "Wii", "WiiWare", "Select", "Import", "View", "Sort", "Settings"] {
      XCTAssertTrue(app.buttons[title].exists, "Collapsed rail lost its \(title) accessibility label")
    }
    XCTAssertFalse(app.buttons["All Games"].hasFocus)
    XCTAssertTrue(app.staticTexts["iCube"].isEnabled)
    // The current native tree exposes the focused card through its platform caption; rail targets are Buttons.
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists,
                  "No game-card text holds focus")
  }

  func testSettingsEntryPaneBackAndDismiss() {
    let app = launch()
    guard focus(app.buttons["Settings"]) else { return }
    XCUIRemote.shared.press(.select)
    let general = app.buttons["General"]
    XCTAssertTrue(general.waitForExistence(timeout: 10))
    record(app, "settings-real-entry")
    guard focus(general, direction: .up) else { return }
    XCUIRemote.shared.press(.right)
    XCTAssertFalse(general.hasFocus)
    XCUIRemote.shared.press(.menu)
    XCTAssertTrue(general.hasFocus)
    XCUIRemote.shared.press(.menu)
    XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
    record(app, "library-after-settings-dismiss")
  }

  func testPerformanceCycleKeepsFocusAndMenuReturnsToSidebar() {
    let app = launch(["-ICubeSettingsPreview", "performance-tuning", "-ICubeSettingsRow", "cpu-engine"])
    let cpu = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "CPU Emulation Engine")).firstMatch
    XCTAssertTrue(cpu.waitForExistence(timeout: 20))
    record(app, "performance-engine-initial")
    XCTAssertTrue(cpu.hasFocus)
    let original = cpu.label
    XCUIRemote.shared.press(.left)
    XCTAssertNotEqual(cpu.label, original)
    let changed = cpu.label
    record(app, "performance-engine-left")
    app.terminate()
    app.launch()
    XCTAssertTrue(cpu.waitForExistence(timeout: 20))
    XCTAssertEqual(cpu.label, changed, "CPU engine did not survive relaunch")
    XCTAssertTrue(cpu.hasFocus)
    XCUIRemote.shared.press(.right)
    XCTAssertEqual(cpu.label, original)
    XCTAssertTrue(cpu.hasFocus)
    XCUIRemote.shared.press(.menu)
    XCTAssertTrue(app.buttons["Performance Tuning"].hasFocus)
  }

  func testRailMenusOpenAndCancel() {
    for (title, content) in [("Import", "Upload via Wi-Fi"), ("View", "Select Games"), ("Sort", "Newest First")] {
      let app = launch()
      guard focus(app.buttons[title]) else { record(app, "unreachable-" + title); return }
      XCUIRemote.shared.press(.select)
      let option = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", content)).firstMatch
      XCTAssertTrue(option.waitForExistence(timeout: 5), "\(title) did not present its menu")
      guard focus(option) else { record(app, "unreachable-option-" + title); return }
      record(app, "rail-menu-" + title.lowercased())
      XCUIRemote.shared.press(.menu)
      let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: option)
      XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed, "\(title) menu remained open")
      let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: app.buttons[title])
      XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed, "Focus did not return to \(title)")
      app.terminate()
    }
  }

  func testRailDoneAndSecondaryPresentation() {
    let app = launch()
    guard focus(app.buttons["Import"]) else { return }
    XCUIRemote.shared.press(.select)
    guard focus(app.buttons["Done"]) else { return }
    XCUIRemote.shared.press(.select)
    let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: app.buttons["Import"])
    XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
    XCUIRemote.shared.press(.select)
    let upload = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Upload via Wi-Fi")).firstMatch
    guard focus(upload, direction: .up) else { return }
    XCUIRemote.shared.press(.select)
    XCTAssertTrue(app.staticTexts["Upload over Wi-Fi"].waitForExistence(timeout: 10), "Add Games was not presented")
    record(app, "rail-import-upload-guide")
    XCUIRemote.shared.press(.menu)
    let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["Upload over Wi-Fi"])
    XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    XCTAssertTrue(app.buttons["Import"].waitForExistence(timeout: 5))
  }

  // One leaf per test keeps a slow/failed capture from exhausting the whole sweep's execution budget.
  private func captureSettingsLeaf(_ leaf: String, title: String) {
    let app = launch(["-ICubeSettingsPreview", leaf])
    let selected = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
    XCTAssertTrue(selected.waitForExistence(timeout: 20), leaf)
    XCTAssertEqual(selected.label, title, "Preview did not select \(leaf)")
    record(app, "settings-" + leaf)
    XCTAssertEqual(app.state, .runningForeground, leaf)
  }

  func testCaptureGeneral() { captureSettingsLeaf("general", title: "General") }
  func testCaptureInterface() { captureSettingsLeaf("interface", title: "Interface") }
  func testCaptureAdvanced() { captureSettingsLeaf("advanced", title: "Advanced") }
  func testCaptureGraphicsVideo() { captureSettingsLeaf("graphics-video", title: "Video") }
  func testVideoDoesNotOfferAdaptiveResolution() {
    let app = launch(["-ICubeSettingsPreview", "graphics-video"])
    XCTAssertTrue(app.buttons["Video"].waitForExistence(timeout: 10))
    for title in ["Enable Auto Internal Resolution", "Target FPS", "Min Scale", "Max Scale", "Show Auto IR OSD"] {
      XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", title)).firstMatch.exists, title)
    }
    record(app, "video-without-adaptive-resolution")
  }
  func testCaptureGraphicsEnhancements() { captureSettingsLeaf("graphics-enhancements", title: "Enhancements") }
  func testCaptureGraphicsHacks() { captureSettingsLeaf("graphics-hacks", title: "Hacks") }
  func testCaptureGraphicsAdvanced() { captureSettingsLeaf("graphics-advanced", title: "Graphics Advanced") }
  func testCaptureShaders() { captureSettingsLeaf("shaders", title: "Shaders") }
  func testCaptureAudio() { captureSettingsLeaf("audio", title: "Audio") }
  func testAudioChoicesKeepTheirSettingNames() {
    let app = launch(["-ICubeSettingsPreview", "audio", "-ICubeSettingsRow", "backend"])
    XCTAssertTrue(app.staticTexts["Audio Backend"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Decoder Quality"].exists)
    let backend = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "AVAudioEngine")).firstMatch
    guard focus(backend) else { return }
    record(app, "audio-named-choices")
    XCUIRemote.shared.press(.menu)
    XCTAssertTrue(app.buttons["Audio"].hasFocus)
  }

  func testDefaultISOManagementOpensAndReturnsToGeneral() {
    let app = launch(["-ICubeSettingsPreview", "general", "-ICubeSettingsRow", "default-iso"])
    let selection = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Default ISO")).firstMatch
    XCTAssertTrue(selection.waitForExistence(timeout: 15))
    XCUIRemote.shared.press(.right)
    guard focus(selection) else { return }
    XCUIRemote.shared.press(.select)
    let clear = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Clear Default ISO")).firstMatch
    XCTAssertTrue(clear.waitForExistence(timeout: 10), "Default ISO management is unreachable")
    record(app, "default-iso-management")
    let done = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Done")).firstMatch
    guard focus(done) else { return }
    XCUIRemote.shared.press(.select)
    let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: clear)
    XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
    XCTAssertTrue(selection.waitForExistence(timeout: 5))
    XCTAssertTrue(selection.hasFocus, "Closing Default ISO lost the invoking General row")
  }

  func testControllersUsesSettingsHeader() {
    let app = launch(["-ICubeSettingsPreview", "controllers"])
    XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 10))
    record(app, "controllers-settings-header")
    XCUIRemote.shared.press(.right)
    XCUIRemote.shared.press(.menu)
    XCTAssertTrue(app.buttons["Controllers"].hasFocus)
  }

  func testUserFolderOpensReadableDetailsAndReturns() {
    let app = launch(["-ICubeSettingsPreview", "debug"])
    let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "User Folder")).firstMatch
    XCTAssertTrue(folder.waitForExistence(timeout: 10))
    XCTAssertTrue(folder.isEnabled, "User Folder has no route to read the complete path")
    guard folder.isEnabled else { return }
    XCUIRemote.shared.press(.right)
    guard focus(folder) else { return }
    XCUIRemote.shared.press(.select)
    let path = app.staticTexts["user-folder-path"]
    XCTAssertTrue(path.waitForExistence(timeout: 10))
    XCTAssertTrue(path.label.hasPrefix("/"))
    XCTAssertTrue(path.isHittable)
    record(app, "user-folder-details")
    XCUIRemote.shared.press(.menu)
    XCTAssertTrue(folder.waitForExistence(timeout: 5))
    XCTAssertFalse(path.exists)
    XCTAssertTrue(folder.hasFocus)
    XCUIRemote.shared.press(.select)
    let done = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Done")).firstMatch
    guard focus(done) else { return }
    XCUIRemote.shared.press(.select)
    let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: path)
    XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
  }
  func testCaptureGameCube() { captureSettingsLeaf("console-gamecube", title: "GameCube") }
  func testCaptureWii() { captureSettingsLeaf("console-wii", title: "Wii") }
  func testCaptureControllers() { captureSettingsLeaf("controllers", title: "Controllers") }
  func testCapturePerformance() { captureSettingsLeaf("performance-tuning", title: "Performance Tuning") }
  func testCaptureDebug() { captureSettingsLeaf("debug", title: "Debug") }
  func testCaptureWebUI() { captureSettingsLeaf("web-ui", title: "Web UI & WebDAV") }
  func testCaptureICloud() { captureSettingsLeaf("icloud", title: "iCloud Sync") }
  func testCaptureNearby() { captureSettingsLeaf("nearby", title: "Nearby Devices") }
  func testCapturePrivacy() { captureSettingsLeaf("privacy", title: "Privacy") }
  func testCaptureAbout() { captureSettingsLeaf("about", title: "About") }

  private func record(_ app: XCUIApplication, _ name: String) {
    print("AUDIT \(name)\n\(app.debugDescription)")
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
