// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest

/// Reusable DEV-only UI runner. Change the JSON actions, not the compiled test bundle.
final class FastInteractionTests: XCTestCase {
  private let app = XCUIApplication(bundleIdentifier: "com.joemattiello.iCube-debug")
  private enum InvalidAction: Error { case invalid(String) }

  override func setUpWithError() throws {
    continueAfterFailure = false
    executionTimeAllowance = 120
    #if !targetEnvironment(simulator)
    try XCTSkipUnless(ProcessInfo.processInfo.environment["ICUBE_ALLOW_DEVICE_CONTROL"] == "1",
                      "Physical interaction requires an explicit device-control window.")
    #endif
  }

  override func tearDown() {
    if let run = testRun, run.hasSucceeded == false, app.state == .runningForeground {
      capture(name: "failure", includeAX: true)
    }
    // Leave DEV where the caller's actions put it. Never quit a game or touch production as cleanup.
    super.tearDown()
  }

  func testActions() throws {
    let raw = ProcessInfo.processInfo.environment["ICUBE_UI_ACTIONS"] ?? "[]"
    guard let data = raw.data(using: .utf8),
          let actions = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
          !actions.isEmpty, actions.count <= 100 else {
      throw InvalidAction.invalid("ICUBE_UI_ACTIONS must contain 1–100 action objects")
    }
    // Reject malformed late steps before any launch/tap/write happens.
    #if os(tvOS)
    try FastInteractionSchema.validate(actions, tvOS: true)
    #else
    try FastInteractionSchema.validate(actions, tvOS: false)
    #endif
    for (index, action) in actions.enumerated() {
      let started = ProcessInfo.processInfo.systemUptime
      let operation = action["op"] as! String
      if operation != "launch" && operation != "activate" {
        XCTAssertEqual(app.state, .runningForeground, "DEV must be foreground; use an explicit launch or activate action")
      }
      switch operation {
      case "launch":
        app.launchArguments = action["arguments"] as? [String] ?? []
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
      case "activate":
        XCTAssertNotEqual(app.state, .notRunning, "Activate will not start a missing DEV session")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
      case "capture":
        capture(name: action["name"] as? String ?? "checkpoint-\(index)", includeAX: action["ax"] as? Bool ?? false)
      case "remote":
        #if os(tvOS)
        let button = remoteButton(action["button"] as! String)!
        if let duration = action["duration"] as? Double {
          XCUIRemote.shared.press(button, forDuration: duration)
        } else {
          XCUIRemote.shared.press(button)
        }
        #else
        throw InvalidAction.invalid("Remote presses require tvOS")
        #endif
      case "tap":
        let target = try element(action)
        XCTAssertTrue(target.isHittable, "Target must be hittable")
        #if os(tvOS)
        XCTAssertTrue(target.hasFocus, "Use remote input to focus a tvOS target before Select")
        XCUIRemote.shared.press(.select)
        #else
        target.tap()
        #endif
      case "type":
        let target = try element(action)
        XCTAssertTrue(target.isHittable)
        #if os(tvOS)
        XCTAssertTrue(target.hasFocus, "Focus the text field before entering text")
        XCUIRemote.shared.press(.select)
        #else
        target.tap()
        #endif
        let text = action["text"] as! String
        if action["clear"] as? Bool == true, let current = target.value as? String,
           current != target.placeholderValue, !current.isEmpty {
          target.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        target.typeText(text)
      case "assert":
        try assertElement(action)
      default: throw InvalidAction.invalid("Unsupported action")
      }
      let seconds = ProcessInfo.processInfo.systemUptime - started
      print("ICUBE_ACTION_TIMING index=\(index) op=\(operation) seconds=\(seconds)")
    }
  }

  private func query(_ action: [String: Any]) -> XCUIElementQuery {
    let kind: XCUIElement.ElementType
    switch action["type"] as? String {
    case "button": kind = .button
    case "textField": kind = .textField
    case "secureTextField": kind = .secureTextField
    case "staticText": kind = .staticText
    case "switch": kind = .switch
    case "slider": kind = .slider
    default: kind = .any
    }
    let all = app.descendants(matching: kind)
    if let identifier = action["identifier"] as? String {
      return all.matching(NSPredicate(format: "identifier == %@", identifier))
    }
    return all.matching(NSPredicate(format: "label == %@", action["label"] as! String))
  }

  private func element(_ action: [String: Any]) throws -> XCUIElement {
    let matches = query(action)
    XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: action["timeout"] as? Double ?? 3))
    guard matches.count == 1 else { throw InvalidAction.invalid("Target must match exactly one element") }
    return matches.firstMatch
  }

  private func assertElement(_ action: [String: Any]) throws {
    let target = query(action).firstMatch
    let shouldExist = action["exists"] as? Bool ?? true
    let predicate = NSPredicate { _, _ in
      guard target.exists == shouldExist else { return false }
      if !shouldExist { return true }
      if let enabled = action["enabled"] as? Bool, target.isEnabled != enabled { return false }
      #if os(tvOS)
      if let focused = action["focused"] as? Bool, target.hasFocus != focused { return false }
      #endif
      if let value = action["value"] as? String, target.value as? String != value { return false }
      if let text = action["valueContains"] as? String,
         (target.value as? String)?.contains(text) != true { return false }
      return true
    }
    let condition = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: action["timeout"] as? Double ?? 3), .completed)
    if shouldExist { XCTAssertEqual(query(action).count, 1, "Assertions must identify one element") }
  }

  private func capture(name: String, includeAX: Bool) {
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
    if includeAX {
      let tree = XCTAttachment(string: app.debugDescription)
      tree.name = name + "-AX"
      tree.lifetime = .keepAlways
      add(tree)
    }
  }

  #if os(tvOS)
  private func remoteButton(_ name: String) -> XCUIRemote.Button? {
    switch name {
    case "up": return .up
    case "down": return .down
    case "left": return .left
    case "right": return .right
    case "select": return .select
    case "menu", "back": return .menu
    case "playPause": return .playPause
    default: return nil
    }
  }
  #endif
}
