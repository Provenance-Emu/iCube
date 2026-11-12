// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// The profile text editor's pure parts: line parsing, colouring, linting and completion.
final class ProfileTextTests: XCTestCase {
  private let keys: [ProfileKey] = [
    ProfileKey(name: "Device", kind: .device),
    ProfileKey(name: "Buttons/A", kind: .control),
    ProfileKey(name: "Buttons/A/Range", kind: .number),
    ProfileKey(name: "Buttons/B", kind: .control),
    ProfileKey(name: "IMUIR/Enabled", kind: .toggle),
    ProfileKey(name: "IMUIR/Total Yaw", kind: .number),
    ProfileKey(name: "Extension", kind: .choice(["None", "Nunchuk", "Classic"])),
    ProfileKey(name: "Rumble/Motor", kind: .output),
  ]
  private let device = "MFi/0/DualSense Wireless Controller"
  private let inputs = ["Button A", "Button B", "L Shoulder", "R Shoulder", "Gyro Pitch Up"]

  /// Stands in for the core's parser: unbalanced backticks or brackets do not parse.
  private func check(_ expression: String) -> ExpressionCheck {
    if expression.isEmpty { return ExpressionCheck(status: .empty, message: "empty") }
    let balanced = expression.filter { $0 == "`" }.count % 2 == 0
      && expression.filter { $0 == "(" }.count == expression.filter { $0 == ")" }.count
    return balanced ? ExpressionCheck(status: .valid, message: "ok") : ExpressionCheck(status: .invalid, message: "Not saved: syntax")
  }

  private func lint(_ text: String, device: String? = nil) -> [ProfileDiagnostic] {
    ProfileTextLinter.lint(text, keys: keys, device: device ?? self.device, inputs: inputs, check: check)
  }

  private func substring(_ text: String, _ range: NSRange) -> String { (text as NSString).substring(with: range) }

  // MARK: Lines

  func test_lines_classifyEachKind_withRangesIntoTheText() {
    let text = "[Profile]\n# note\n\nButtons/A = `Button A`\nnonsense\r\nIMUIR/Enabled=True"
    let lines = ProfileTextDocument.lines(of: text)
    XCTAssertEqual(lines.map(\.number), [1, 2, 3, 4, 5, 6])
    XCTAssertEqual(lines[0].content, .section("Profile"))
    XCTAssertEqual(lines[1].content, .comment)
    XCTAssertEqual(lines[2].content, .blank)
    guard case .entry(let key, let value, let keyRange, let valueRange, let equals) = lines[3].content else { return XCTFail("entry") }
    XCTAssertEqual(key, "Buttons/A")
    XCTAssertEqual(value, "`Button A`")
    XCTAssertEqual(substring(text, keyRange), "Buttons/A")
    XCTAssertEqual(substring(text, valueRange), "`Button A`")
    XCTAssertEqual(substring(text, NSRange(location: equals, length: 1)), "=")
    XCTAssertEqual(lines[4].content, .malformed)
    XCTAssertEqual(substring(text, lines[4].range), "nonsense", "a CRLF's carriage return is not part of the line")
    guard case .entry(let tight, let tightValue, _, _, _) = lines[5].content else { return XCTFail("entry") }
    XCTAssertEqual([tight, tightValue], ["IMUIR/Enabled", "True"])
  }

  func test_normalized_addsTheHeaderABarePasteLacks_andLeavesAFullFileAlone() {
    XCTAssertEqual(ProfileTextDocument.normalized("Buttons/A = `Button A`"), "[Profile]\nButtons/A = `Button A`\n")
    XCTAssertEqual(ProfileTextDocument.normalized("[Profile]\nButtons/A = `Button A`\n"), "[Profile]\nButtons/A = `Button A`\n")
  }

  // MARK: Colouring

  func test_tokens_colourAnExpressionsParts() {
    let text = "Buttons/A = toggle(`Button A`) | !`L Shoulder` & $speed > 0.5 /* note */"
    let tokens = ProfileTextHighlighter.tokens(for: text)
    func texts(_ kind: ProfileTextToken.Kind) -> [String] { tokens.filter { $0.kind == kind }.map { substring(text, $0.range) } }
    XCTAssertEqual(texts(.key), ["Buttons/A"])
    XCTAssertEqual(texts(.punctuation), ["="])
    XCTAssertEqual(texts(.function), ["toggle"])
    XCTAssertEqual(texts(.control), ["`Button A`", "`L Shoulder`"])
    XCTAssertEqual(texts(.variable), ["$speed"])
    XCTAssertEqual(texts(.number), ["0.5"])
    XCTAssertEqual(texts(.comment), ["/* note */"])
    XCTAssertEqual(texts(.operatorSymbol), ["(", ")", "|", "!", "&", ">"])
  }

  func test_tokens_aDeviceIsAName_notAnExpression_andACommaDecimalIsOneNumber() {
    let deviceLine = ProfileTextHighlighter.tokens(for: "Device = MFi/0/DualSense Wireless Controller")
    XCTAssertEqual(deviceLine.map(\.kind), [.key, .punctuation])
    let radius = "Nunchuk/Stick/Radius = 100,000000"
    let number = ProfileTextHighlighter.tokens(for: radius).first { $0.kind == .number }
    XCTAssertEqual(number.map { substring(radius, $0.range) }, "100,000000")
  }

  func test_controlNames_areTheBacktickedNames() {
    XCTAssertEqual(ProfileTextHighlighter.controlNames(in: "`Button A` | `XInput/0/Gamepad:Button B`"), ["Button A", "XInput/0/Gamepad:Button B"])
  }

  // MARK: Linting

  func test_lint_aCleanProfile_hasNoProblems() {
    let text = "[Profile]\nDevice = \(device)\nButtons/A = `Button A` | `Button B`\nButtons/A/Range = 100,000000\nIMUIR/Enabled = True\nIMUIR/Total Yaw = 15\nExtension = Nunchuk\n"
    XCTAssertEqual(lint(text), [])
  }

  func test_lint_flagsWhatTheCoreWouldSilentlyDropOrMisread() {
    let text = "[Profile]\nnonsense\nButtons/A = `Button A\nButons/B = `Button B`\nIMUIR/Total Yaw =\nIMUIR/Enabled = maybe(\n[Other]\nButtons/B = whatever("
    let found = lint(text).map { "\($0.line) \($0.severity) \($0.message)" }
    XCTAssertEqual(found, [
      "2 error Not a Key = Value line. It would be ignored.",
      "3 error Not saved: syntax",
      "4 warning Unknown key. Did you mean Buttons/B?",
      "5 error A number is missing.",
      "6 error Not saved: syntax",
      "7 warning Only [Profile] is read. [Other] and what follows it are ignored.",
    ], "nothing after [Other] is judged: the core never reads it")
  }

  func test_lint_namesAnInputTheDeviceDoesNotHave_butNotAnotherDevicesInput() {
    let text = "Buttons/A = `Button Q` | `XInput/0/Gamepad:Whatever`"
    XCTAssertEqual(lint(text).map(\.message), ["DualSense Wireless Controller has no input named Button Q."])
    XCTAssertEqual(lint(text).first?.severity, .warning)
    // A profile written for another device is not judged by this device's inputs.
    XCTAssertEqual(lint("Device = MFi/0/Xbox Wireless Controller\n" + text), [])
  }

  func test_lint_aKeySetTwice_andAChoiceThatIsNotOne() {
    let found = lint("Buttons/A = `Button A`\nButtons/A = `Button B`\nExtension = Guitarr").map { "\($0.line) \($0.message)" }
    XCTAssertEqual(found, ["2 Buttons/A is also set on line 1. This line wins.", "3 Not one of: None, Nunchuk, Classic."])
  }

  /// `Rumble` is an output of the pad, not one of its inputs: it must not be reported as missing.
  func test_lint_anOutputsBinding_isJudgedByItsParseOnly() {
    XCTAssertEqual(lint("Rumble/Motor = `Rumble`"), [])
    XCTAssertEqual(lint("Rumble/Motor = `Rumble").map(\.severity), [.error])
  }

  func test_nearest_findsATypo_andNothingForAStranger() {
    let names = keys.map(\.name)
    XCTAssertEqual(ProfileTextLinter.nearest(to: "buttons/a", in: names), "Buttons/A")
    XCTAssertEqual(ProfileTextLinter.nearest(to: "IMUIR/Total Yew", in: names), "IMUIR/Total Yaw")
    XCTAssertNil(ProfileTextLinter.nearest(to: "Hotkeys/Sideways Toggle", in: names))
  }

  // MARK: Completion

  func test_completion_keys_onANewLine_writeKeyAndEquals() {
    let text = "[Profile]\nbut"
    let found = ProfileTextCompletion.suggestions(text: text, cursor: (text as NSString).length, keys: keys, inputs: inputs)
    XCTAssertEqual(found.map(\.title), ["Buttons/A", "Buttons/A/Range", "Buttons/B"])
    XCTAssertEqual(found.first?.insertion, "Buttons/A = ")
    XCTAssertEqual(found.first.map { substring(text, $0.range) }, "but")
  }

  func test_completion_keys_skipWhatTheTextAlreadySets() {
    let text = "Buttons/A = `Button A`\nbut"
    let found = ProfileTextCompletion.suggestions(text: text, cursor: (text as NSString).length, keys: keys, inputs: inputs)
    XCTAssertEqual(found.map(\.title), ["Buttons/A/Range", "Buttons/B"])
  }

  func test_completion_inAnOpenBacktick_offersTheDevicesInputs_andClosesIt() {
    let text = "Buttons/A = `sh"
    let found = ProfileTextCompletion.suggestions(text: text, cursor: (text as NSString).length, keys: keys, inputs: inputs)
    XCTAssertEqual(found.map(\.title), ["L Shoulder", "R Shoulder"], "contains, case-insensitive")
    XCTAssertEqual(found.first?.insertion, "`L Shoulder`")
    XCTAssertEqual(found.first.map { substring(text, $0.range) }, "`sh", "the fragment and its backtick are replaced")
  }

  func test_completion_aBareWord_offersFunctionsThenInputs() {
    let text = "Buttons/A = to"
    let found = ProfileTextCompletion.suggestions(text: text, cursor: (text as NSString).length, keys: keys, inputs: inputs)
    XCTAssertEqual(found.map(\.title), ["toggle(", "Button A", "Button B"])
  }

  func test_completion_toggleAndChoiceValues_andNothingInAComment() {
    let toggle = "IMUIR/Enabled = "
    XCTAssertEqual(
      ProfileTextCompletion.suggestions(text: toggle, cursor: (toggle as NSString).length, keys: keys, inputs: inputs).map(\.title),
      ["True", "False"])
    let choice = "Extension = "
    XCTAssertEqual(
      ProfileTextCompletion.suggestions(text: choice, cursor: (choice as NSString).length, keys: keys, inputs: inputs).map(\.title),
      ["None", "Nunchuk", "Classic"])
    XCTAssertEqual(ProfileTextCompletion.suggestions(text: "# but", cursor: 5, keys: keys, inputs: inputs), [])
  }

  // MARK: Model

  @MainActor
  private final class FakeIO: ProfileTextIO {
    var stored = "[Profile]\nButtons/A = `Button A`\n"
    var applied: [String] = []
    var refuses = false
    let keys: [ProfileKey]
    init(keys: [ProfileKey]) { self.keys = keys }
    func profileText(for slot: PlayerSlot) -> String { stored }
    func profileKeys(for slot: PlayerSlot) -> [ProfileKey] { keys }
    func boundQualifier(for slot: PlayerSlot) -> String { "MFi/0/DualSense Wireless Controller" }
    func inputNames(forQualifier qualifier: String) -> [String] { ["Button A", "Button B"] }
    func check(_ expression: String) -> ExpressionCheck {
      expression.filter { $0 == "`" }.count % 2 == 0
        ? ExpressionCheck(status: .valid, message: "ok") : ExpressionCheck(status: .invalid, message: "Not saved: syntax")
    }
    func apply(_ text: String, to slot: PlayerSlot) -> Bool {
      guard !refuses else { return false }
      applied.append(text)
      stored = text
      return true
    }
  }

  @MainActor
  func test_model_appliesOnlyAChangedTextWithoutErrors_andReadsBackWhatTheCoreKept() {
    let io = FakeIO(keys: keys)
    let model = ProfileTextEditorModel(slot: PlayerSlot(kind: .gameCube, port: 1), io: io)
    model.load()
    XCTAssertFalse(model.canApply, "nothing changed")
    model.text = "Buttons/A = `Button B"
    XCTAssertEqual(model.errorCount, 1)
    XCTAssertFalse(model.apply(), "an error blocks Apply")
    XCTAssertEqual(io.applied, [])
    model.text = "Buttons/A = `Button B`"
    XCTAssertTrue(model.canApply)
    XCTAssertTrue(model.apply())
    XCTAssertEqual(io.applied, ["[Profile]\nButtons/A = `Button B`\n"], "a bare paste gets its header")
    XCTAssertFalse(model.isChanged, "the editor now shows what the port holds")
    XCTAssertEqual(model.exportName, "Player 1 - DualSense Wireless Controller")
  }

  @MainActor
  func test_model_revert_import_andAcceptingACompletion() {
    let io = FakeIO(keys: keys)
    let model = ProfileTextEditorModel(slot: PlayerSlot(kind: .gameCube, port: 1), io: io)
    model.load()
    model.replaceText(with: "Buttons/B = `Button A`\r\nBut")
    XCTAssertEqual(model.text, "Buttons/B = `Button A`\nBut", "CRLF from a Windows file becomes LF")
    model.cursor = (model.text as NSString).length
    let completion = try? XCTUnwrap(model.completions.first)
    XCTAssertEqual(completion?.title, "Buttons/A")
    if let completion { model.accept(completion) }
    XCTAssertEqual(model.text, "Buttons/B = `Button A`\nButtons/A = ")
    XCTAssertEqual(model.cursor, (model.text as NSString).length)
    model.revert()
    XCTAssertEqual(model.text, io.stored)
    io.refuses = true
    model.text = "Buttons/A = `Button B`"
    XCTAssertFalse(model.apply(), "the core could not read it")
    XCTAssertTrue(model.isChanged)
  }
}
