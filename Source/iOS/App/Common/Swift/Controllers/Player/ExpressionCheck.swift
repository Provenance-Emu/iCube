// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The raw-expression editor's verdict on its text (controller hub spec, edge case "An Advanced
/// expression does not parse"): what it shows and whether Save is allowed. The parse itself is the
/// core's (`DOLControllerSettingsBridge.parse(expression:)`); this only maps its answer.
///
/// The check has to happen before saving: `ControlReference::SetExpression` installs a text that
/// does not parse and only returns the error (ControlReference.cpp:52-59), and the mapping bridge
/// discards that return value (TVControllerMappingBridge.mm:543).
struct ExpressionCheck: Equatable {
  enum Status: Equatable {
    case valid
    /// Blank: saving it unbinds the control.
    case empty
    case invalid
  }

  let status: Status
  let message: String

  var canSave: Bool { status != .invalid }

  init(status: Status, message: String) {
    self.status = status
    self.message = message
  }

  init(parseStatus: ExpressionParseStatus, parserMessage: String?) {
    switch parseStatus {
    case .successful:
      self.init(status: .valid, message: L("The expression is valid."))
    case .empty:
      self.init(status: .empty, message: L("Empty: saving unbinds this control."))
    case .syntaxError:
      self.init(
        status: .invalid,
        message: parserMessage.map { String(format: L("Not saved: %@"), $0) } ?? L("Not saved: the expression does not parse."))
    @unknown default:
      self.init(status: .invalid, message: L("Not saved: the expression does not parse."))
    }
  }
}
