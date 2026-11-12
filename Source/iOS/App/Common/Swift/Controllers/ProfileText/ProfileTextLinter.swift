// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One thing wrong with a line of a profile's text.
struct ProfileDiagnostic: Equatable, Identifiable {
  enum Severity: Equatable {
    /// The core would misread or drop the line: Apply is refused until it is fixed.
    case error
    /// Probably a mistake, but the profile still loads.
    case warning
  }

  /// 1-based.
  let line: Int
  /// The line's range in the text.
  let range: NSRange
  let severity: Severity
  let message: String

  var id: String { "\(line)-\(message)" }
}

/// Checks a profile's text against the port it is for, before it is applied. The core reads a
/// profile without complaint whatever it holds: an unknown key is ignored, a line without `=` is
/// dropped, and an expression that does not parse is installed and matches nothing. Each of those
/// is a mapping that silently does not work, so the editor says so per line.
///
/// Pure: the keys, the device's inputs and the expression parser are passed in.
enum ProfileTextLinter {
  static func lint(
    _ text: String, keys: [ProfileKey], device: String, inputs: [String], check: (String) -> ExpressionCheck
  ) -> [ProfileDiagnostic] {
    var diagnostics: [ProfileDiagnostic] = []
    let known = Dictionary(keys.map { ($0.name, $0.kind) }, uniquingKeysWith: { first, _ in first })
    var seen: [String: Int] = [:]
    var inProfile = true
    var deviceInText: String?
    let lines = ProfileTextDocument.lines(of: text)
    for line in lines {
      if case .entry(let key, let value, _, _, _) = line.content, key == ProfileTextHighlighter.deviceKey { deviceInText = value }
    }
    // The inputs listed are the bound device's: a profile naming another device is not judged by them.
    let judgesInputs = !inputs.isEmpty && (deviceInText == nil || deviceInText == device)

    func report(_ line: ProfileTextLine, _ severity: ProfileDiagnostic.Severity, _ message: String) {
      diagnostics.append(ProfileDiagnostic(line: line.number, range: line.range, severity: severity, message: message))
    }

    for line in lines {
      switch line.content {
      case .blank, .comment:
        continue
      case .malformed:
        report(line, .error, L("Not a Key = Value line. It would be ignored."))
      case .section(let name):
        inProfile = name == ProfileTextDocument.sectionName
        if !inProfile { report(line, .warning, String(format: L("Only [Profile] is read. [%@] and what follows it are ignored."), name)) }
      case .entry(let key, let value, _, _, _):
        guard inProfile else { continue }
        if let first = seen[key] {
          report(line, .warning, String(format: L("%@ is also set on line %d. This line wins."), key, first))
        }
        seen[key] = line.number
        guard let kind = known[key] else {
          let suggestion = nearest(to: key, in: keys.map(\.name))
          report(line, .warning, suggestion.map { String(format: L("Unknown key. Did you mean %@?"), $0) } ?? L("Unknown key. It is ignored."))
          continue
        }
        lint(value: value, of: kind, line: line, judgesInputs: judgesInputs, device: device, inputs: inputs, check: check, report: report)
      }
    }
    return diagnostics
  }

  private static func lint(
    value: String, of kind: ProfileKey.Kind, line: ProfileTextLine, judgesInputs: Bool, device: String, inputs: [String],
    check: (String) -> ExpressionCheck, report: (ProfileTextLine, ProfileDiagnostic.Severity, String) -> Void
  ) {
    switch kind {
    case .device:
      if value.isEmpty { report(line, .warning, L("No device: every binding below has nothing to read.")) }
    case .control:
      lintExpression(value, line: line, judgesInputs: judgesInputs, device: device, inputs: inputs, check: check, report: report)
    case .output:
      // It names outputs (`Rumble`), which the input list does not hold: only the parse is judged.
      lintExpression(value, line: line, judgesInputs: false, device: device, inputs: inputs, check: check, report: report)
    case .number:
      if value.isEmpty {
        report(line, .error, L("A number is missing."))
      } else if !isNumber(value) {
        lintExpression(value, line: line, judgesInputs: judgesInputs, device: device, inputs: inputs, check: check, report: report)
      }
    case .toggle:
      if !ProfileExpressionSyntax.booleans.contains(value) {
        if value.isEmpty {
          report(line, .error, L("True or False is missing."))
        } else {
          lintExpression(value, line: line, judgesInputs: judgesInputs, device: device, inputs: inputs, check: check, report: report)
        }
      }
    case .choice(let choices):
      if !choices.contains(value), check(value).status != .valid || isBareWord(value) {
        report(line, .warning, String(format: L("Not one of: %@."), choices.joined(separator: ", ")))
      }
    }
  }

  private static func lintExpression(
    _ value: String, line: ProfileTextLine, judgesInputs: Bool, device: String, inputs: [String],
    check: (String) -> ExpressionCheck, report: (ProfileTextLine, ProfileDiagnostic.Severity, String) -> Void
  ) {
    let verdict = check(value)
    guard verdict.status != .invalid else {
      report(line, .error, verdict.message)
      return
    }
    guard judgesInputs else { return }
    // `Device:Input` names another device's input, which this list cannot judge.
    for name in ProfileTextHighlighter.controlNames(in: value) where !name.contains(":") && !inputs.contains(name) {
      report(line, .warning, String(format: L("%1$@ has no input named %2$@."), deviceName(device), name))
    }
  }

  /// "DualSense Wireless Controller" from `MFi/0/DualSense Wireless Controller`.
  static func deviceName(_ qualifier: String) -> String {
    qualifier.split(separator: "/", maxSplits: 2).last.map(String.init) ?? qualifier
  }

  /// `1`, `-0.5`, `100,000000` (a profile saved under a comma-decimal locale).
  static func isNumber(_ value: String) -> Bool {
    Double(value.replacingOccurrences(of: ",", with: ".")) != nil
  }

  private static func isBareWord(_ value: String) -> Bool {
    !value.isEmpty && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " }
  }

  // MARK: Did you mean

  /// The known key closest to `key`: the same but for case, or within a few edits. nil when
  /// nothing is close enough to be a likely typo.
  static func nearest(to key: String, in keys: [String]) -> String? {
    if let sameButForCase = keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) { return sameButForCase }
    let limit = max(1, min(3, key.count / 3))
    let lowered = Array(key.lowercased())
    var best: (name: String, distance: Int)?
    for candidate in keys where abs(candidate.count - key.count) <= limit {
      let distance = editDistance(lowered, Array(candidate.lowercased()), limit: limit)
      if distance <= limit, distance < (best?.distance ?? Int.max) { best = (candidate, distance) }
    }
    return best?.name
  }

  /// Levenshtein distance, given up (as `limit + 1`) once a whole row exceeds `limit`.
  static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0 ... b.count)
    for (i, left) in a.enumerated() {
      var current = [i + 1] + Array(repeating: 0, count: b.count)
      for (j, right) in b.enumerated() {
        current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1))
      }
      if (current.min() ?? 0) > limit { return limit + 1 }
      previous = current
    }
    return previous[b.count]
  }
}
