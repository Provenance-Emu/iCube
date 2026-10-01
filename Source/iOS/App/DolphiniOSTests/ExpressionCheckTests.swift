// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

/// The raw-expression check: the core's own parser through the app-side bridge (no core change),
/// and the mapping of its answer to what the editor shows. Only backquoted forms are used: a bare
/// word can parse as a working bareword fallback even when the full parse reports a syntax error.
final class ExpressionCheckTests: XCTestCase {

  // MARK: The parser, through DOLControllerSettingsBridge

  func test_parser_aBackquotedInputParses() {
    let result = DOLControllerSettingsBridge.parse(expression: "`Button A`")
    XCTAssertEqual(result.status, .successful)
    XCTAssertNil(result.message)
  }

  func test_parser_anOrOfTwoInputsParses() {
    XCTAssertEqual(DOLControllerSettingsBridge.parse(expression: "`Button A` | `Button B`").status, .successful)
  }

  func test_parser_blankIsEmpty() {
    let result = DOLControllerSettingsBridge.parse(expression: "   ")
    XCTAssertEqual(result.status, .empty)
    XCTAssertNil(result.message)
  }

  func test_parser_anUnclosedParenIsASyntaxErrorWithTheParsersMessage() {
    let result = DOLControllerSettingsBridge.parse(expression: "(`Button A`")
    XCTAssertEqual(result.status, .syntaxError)
    XCTAssertFalse((result.message ?? "").isEmpty, "the parser explains what it expected")
  }

  // MARK: Mapping

  func test_valid_canBeSaved() {
    let check = ExpressionCheck(parseStatus: .successful, parserMessage: nil)
    XCTAssertEqual(check.status, .valid)
    XCTAssertTrue(check.canSave)
  }

  func test_empty_canBeSaved_itUnbindsTheControl() {
    let check = ExpressionCheck(parseStatus: .empty, parserMessage: nil)
    XCTAssertEqual(check.status, .empty)
    XCTAssertTrue(check.canSave)
  }

  func test_syntaxError_cannotBeSaved_andShowsTheParsersMessage() {
    let check = ExpressionCheck(parseStatus: .syntaxError, parserMessage: "Expected closing paren.")
    XCTAssertEqual(check.status, .invalid)
    XCTAssertFalse(check.canSave)
    XCTAssertEqual(check.message, "Not saved: Expected closing paren.")
  }

  func test_syntaxErrorWithoutAMessage_stillExplains() {
    XCTAssertEqual(
      ExpressionCheck(parseStatus: .syntaxError, parserMessage: nil).message,
      "Not saved: the expression does not parse.")
  }
}
