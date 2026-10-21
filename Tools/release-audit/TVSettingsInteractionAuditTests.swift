import XCTest
final class TVSettingsInteractionAuditTests: XCTestCase {
  var app: XCUIApplication!
  override func setUp() {
    continueAfterFailure = false
    app = XCUIApplication(bundleIdentifier: "com.joemattiello.iCube-debug")
    app.launchArguments = ["-ICubePausePreview", "-ICubePausePane", "settings", "-onboarding_seen_v1", "YES", "-SCREENSHOT_MODE", "0"]
    app.launch()
  }
  func openSettings() {
    XCTAssertTrue(app.buttons["pause.tile.resume"].waitForExistence(timeout: 10))
    for _ in 0..<4 { XCUIRemote.shared.press(.down) }
    for _ in 0..<3 { XCUIRemote.shared.press(.right) }
    XCTAssertTrue(app.buttons["pause.tile.settings"].hasFocus)
    XCUIRemote.shared.press(.select)
    XCTAssertTrue(app.buttons["General"].waitForExistence(timeout: 5))
  }
  func testToggleFirstBackReturnsCategorySecondBackDismisses() {
    openSettings()
    XCUIRemote.shared.press(.right)
    let focused = app.buttons.allElementsBoundByIndex.first { $0.hasFocus }
    XCTAssertTrue(focused?.label.hasPrefix("Enable Dual Core") == true)
    record("toggle-before-back")
    XCUIRemote.shared.press(.menu)
    record("toggle-after-first-back")
    XCTAssertTrue(app.buttons["General"].exists, "First Back must preserve Settings")
    XCTAssertTrue(app.buttons["General"].hasFocus, "First Back must focus selected category")
    XCUIRemote.shared.press(.menu)
    record("toggle-after-second-back")
    XCTAssertFalse(app.buttons["General"].exists, "Second Back must close full Settings modal")
    XCTAssertTrue(app.buttons["pause.tile.settings"].hasFocus)
  }
  func openGameCubeLanguage() {
    openSettings()
    for _ in 0..<9 { XCUIRemote.shared.press(.down) }
    XCTAssertTrue(app.buttons["GameCube"].hasFocus)
    XCUIRemote.shared.press(.select)
    XCUIRemote.shared.press(.right)
    XCTAssertTrue(language.hasFocus)
  }
  var language: XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "System Language,")).firstMatch }
  func testChoiceFirstBackReturnsCategorySecondBackDismisses() {
    openGameCubeLanguage()
    let before = language.label
    record("choice-before-back")
    XCUIRemote.shared.press(.menu)
    record("choice-after-first-back")
    XCTAssertTrue(app.buttons["GameCube"].exists, "First Back must preserve Settings")
    XCTAssertTrue(app.buttons["GameCube"].hasFocus, "First Back must focus selected category")
    XCTAssertEqual(language.label, before, "Back must not change System Language")
    XCUIRemote.shared.press(.menu)
    record("choice-after-second-back")
    XCTAssertFalse(app.buttons["GameCube"].exists, "Second Back must close full Settings modal")
    XCTAssertTrue(app.buttons["pause.tile.settings"].hasFocus)
  }
  func testChoiceLeftReturnsCategoryWithoutMutating() {
    openGameCubeLanguage()
    continueAfterFailure = true
    let before = language.label
    record("choice-before-left")
    XCUIRemote.shared.press(.left)
    record("choice-after-left")
    XCTAssertEqual(language.label, before, "Left must not cycle System Language")
    XCTAssertTrue(app.buttons["GameCube"].hasFocus, "Left must return to selected category")

  }
  private var choicePanel: XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "menu.choice-panel.")).firstMatch
  }
  private var choiceOptions: XCUIElementQuery {
    app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier CONTAINS %@", "menu.row.", "#"))
  }
  private func waitForFocus(_ target: XCUIElement, _ message: String) {
    let condition = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in target.exists && target.hasFocus }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: 5), .completed, message)
  }
  private func focusedButton() -> XCUIElement? {
    app.buttons.allElementsBoundByIndex.first { $0.hasFocus }
  }
  private func focus(_ target: XCUIElement) {
    XCTAssertTrue(target.waitForExistence(timeout: 5))
    for _ in 0..<20 {
      if target.hasFocus { return }
      guard let focused = focusedButton() else { XCTFail("No focused button"); return }
      let dx = target.frame.midX - focused.frame.midX
      let dy = target.frame.midY - focused.frame.midY
      XCUIRemote.shared.press(abs(dy) > 50 ? (dy > 0 ? .down : .up) : (dx > 0 ? .right : .left))
    }
    record("focus-failure")
    XCTFail("Cannot focus \(target.identifier)")
  }
  func testChoiceSelectOpensPanelWithoutMutating() {
    openGameCubeLanguage()
    let before = language.label
    XCUIRemote.shared.press(.select)
    XCTAssertTrue(choicePanel.waitForExistence(timeout: 5), "Select must open the choice panel")
    record("choice-after-select")
    XCTAssertEqual(language.label, before, "Opening choice panel must not mutate selected value")
    XCTAssertGreaterThan(choiceOptions.count, 1, "Choice panel must list individual options")
    XCTAssertTrue(choiceOptions.allElementsBoundByIndex.contains { $0.label.contains("English") }, "Choice panel lists current English option")
    XCUIRemote.shared.press(.menu)
    waitForFocus(language, "Cancel restores origin choice focus")
    XCTAssertEqual(language.label, before)
  }
  func testChoiceNavigationAndCancelPreserveValueAndOriginFocus() {
    openGameCubeLanguage()
    let before = language.label
    XCUIRemote.shared.press(.select)
    XCTAssertTrue(choicePanel.waitForExistence(timeout: 5))
    XCTAssertGreaterThan(choiceOptions.count, 1)
    let initial = focusedButton()?.identifier
    XCUIRemote.shared.press(.down)
    record("choice-navigated-before-cancel")
    XCTAssertNotEqual(focusedButton()?.identifier, initial, "Remote Down moves among options")
    XCTAssertEqual(language.label, before, "Browsing options does not commit a value")
    XCUIRemote.shared.press(.menu)
    record("choice-cancelled")
    XCTAssertFalse(choicePanel.exists)
    waitForFocus(language, "Menu returns focus to original choice row")
    XCTAssertEqual(language.label, before, "Menu cancels without mutation")
    XCUIRemote.shared.press(.menu)
    waitForFocus(app.buttons["GameCube"], "Back after chooser cancellation returns category")
    XCUIRemote.shared.press(.menu)
    XCTAssertFalse(app.buttons["GameCube"].exists)
    waitForFocus(app.buttons["pause.tile.settings"], "Second Back closes Settings")
  }
  func testPerformanceHUDLongPressOpensSubmenuAndBackReturnsTile() {
    let hud = app.buttons["pause.tile.perf-hud"]
    focus(hud)
    let before = hud.value as? String
    XCUIRemote.shared.press(.select, forDuration: 1.2)
    record("hud-long-press-submenu")
    let fps = app.buttons["menu.row.hud-fps"]
    XCTAssertTrue(fps.waitForExistence(timeout: 5), "Long press opens HUD settings submenu")
    for id in ["hud-fps", "hud-vps", "hud-speed", "hud-vblank", "hud-graphs", "hud-overlayStats"] {
      XCTAssertTrue(app.buttons["menu.row." + id].exists, "Missing HUD option \(id)")
    }
    XCTAssertTrue(app.staticTexts["Performance HUD"].exists)
    XCTAssertTrue(focusedButton()?.identifier.hasPrefix("menu.row.hud-") == true, "Submenu receives remote focus")
    focus(fps)
    let originalFPS = fps.value as? String ?? fps.label
    XCUIRemote.shared.press(.select)
    record("hud-fps-toggled")
    let toggledFPS = fps.value as? String ?? fps.label
    XCUIRemote.shared.press(.select)
    XCTAssertEqual(fps.value as? String ?? fps.label, originalFPS, "Restore captured FPS setting")
    XCTAssertNotEqual(toggledFPS, originalFPS, "Select toggles live FPS setting")
    XCUIRemote.shared.press(.menu)
    record("hud-submenu-back")
    waitForFocus(hud, "Menu closes HUD submenu and restores tile focus")
    XCTAssertEqual(hud.value as? String, before)
  }
  func testDisabledRowShowsDependencyAndBackReturnsCategory() {
    openSettings()
    for _ in 0..<5 { XCUIRemote.shared.press(.down) }
    XCTAssertTrue(app.buttons["Hacks"].hasFocus)
    XCUIRemote.shared.press(.select)
    XCUIRemote.shared.press(.right)
    record("hacks-content")
    let disabled = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Bounding Box Sync,")).firstMatch
    XCTAssertTrue(disabled.exists)
    XCTAssertFalse(disabled.isEnabled)
    continueAfterFailure = true
    XCTAssertTrue(disabled.label.contains("Unavailable"), "Disabled choice must explain its dependency")
    XCUIRemote.shared.press(.menu)
    record("hacks-after-first-back")
    XCTAssertTrue(app.buttons["Hacks"].hasFocus)
    XCUIRemote.shared.press(.menu)
    XCTAssertFalse(app.buttons["Hacks"].exists)
  }
  func testWiiChoiceFirstBackReturnsCategorySecondBackDismisses() {
    openSettings()
    for _ in 0..<10 { XCUIRemote.shared.press(.down) }
    XCTAssertTrue(app.buttons["Wii"].hasFocus)
    XCUIRemote.shared.press(.select)
    XCUIRemote.shared.press(.right)
    record("wii-content-initial")
    let remote = XCUIRemote.shared
    for _ in 0..<8 {
      if language.hasFocus { break }
      let focused = app.buttons.allElementsBoundByIndex.first { $0.hasFocus }
      remote.press(language.frame.midY < (focused?.frame.midY ?? 0) ? .up : .down)
    }
    XCTAssertTrue(language.hasFocus)
    let before = language.label
    record("wii-choice-before-back")
    remote.press(.menu)
    record("wii-choice-after-first-back")
    XCTAssertTrue(app.buttons["Wii"].exists)
    XCTAssertTrue(app.buttons["Wii"].hasFocus)
    XCTAssertEqual(language.label, before)
    remote.press(.menu)
    record("wii-choice-after-second-back")
    XCTAssertFalse(app.buttons["Wii"].exists)
    XCTAssertTrue(app.buttons["pause.tile.settings"].hasFocus)
  }
  func testChoiceExplicitCommitAndRestore() {
    openGameCubeLanguage()
    let original = language.value as? String
    XCTAssertTrue(original?.contains("English") == true, "Owned simulator baseline must be English")
    XCUIRemote.shared.press(.select)
    XCTAssertTrue(choicePanel.waitForExistence(timeout: 5))
    let german = choiceOptions.matching(NSPredicate(format: "label BEGINSWITH %@", "German")).firstMatch
    focus(german)
    XCUIRemote.shared.press(.select)
    waitForFocus(language, "Committing option restores original row focus")
    let committed = language.value as? String
    record("choice-german-committed")
    // Restore before asserting the observed commit so failures preserve baseline.
    XCUIRemote.shared.press(.select)
    XCTAssertTrue(choicePanel.waitForExistence(timeout: 5))
    let english = choiceOptions.matching(NSPredicate(format: "label BEGINSWITH %@", "English")).firstMatch
    focus(english)
    XCUIRemote.shared.press(.select)
    waitForFocus(language, "Restoring option returns original row focus")
    record("choice-english-restored")
    XCTAssertEqual(language.value as? String, original)
    XCTAssertTrue(committed?.contains("German") == true, "Selecting highlighted option explicitly commits it")
  }
  func testPauseSettingsRepeatedBackRoundtrip() {
    for iteration in 1...3 {
      focus(app.buttons["pause.tile.settings"])
      XCUIRemote.shared.press(.select)
      XCTAssertTrue(app.buttons["General"].waitForExistence(timeout: 5))
      XCUIRemote.shared.press(.right)
      XCTAssertTrue(focusedButton()?.identifier.hasPrefix("menu.row.") == true)
      XCUIRemote.shared.press(.menu)
      waitForFocus(app.buttons["General"], "First Back returns category on iteration \(iteration)")
      XCUIRemote.shared.press(.menu)
      waitForFocus(app.buttons["pause.tile.settings"], "Second Back closes modal on iteration \(iteration)")
      XCTAssertFalse(app.buttons["General"].exists)
      record("pause-settings-repeat-\(iteration)")
    }
  }
  func testLibrarySettingsFirstBackReturnsCategorySecondBackDismisses() {
    app.terminate()
    // Demo catalogue exercises the real library rail without booting a game.
    app.launchArguments = ["-onboarding_seen_v1", "YES", "-SCREENSHOT_MODE", "1"]
    app.launch()
    let settings = app.buttons.matching(NSPredicate(format: "label == %@", "Settings")).firstMatch
    XCTAssertTrue(settings.waitForExistence(timeout: 10))
    focus(settings)
    record("library-settings-entry")
    XCUIRemote.shared.press(.select)
    let general = app.buttons["settings.category.general"]
    XCTAssertTrue(general.waitForExistence(timeout: 5))
    XCUIRemote.shared.press(.right)
    XCTAssertTrue(focusedButton()?.identifier.hasPrefix("menu.row.") == true)
    record("library-settings-content")
    XCUIRemote.shared.press(.menu)
    record("library-settings-first-back")
    waitForFocus(general, "First Back preserves Settings and returns category")
    XCUIRemote.shared.press(.menu)
    record("library-settings-second-back")
    XCTAssertFalse(general.exists, "Second Back closes the full library Settings modal")
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Settings")).allElementsBoundByIndex.contains { $0.hasFocus }, "Focus returns to library Settings entry")
  }
  func record(_ name: String) {
    let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-AX"; tree.lifetime = .keepAlways; add(tree)
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    print("AXTREE " + app.debugDescription)
  }
}
