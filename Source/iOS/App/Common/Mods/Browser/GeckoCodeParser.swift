// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One Gecko code as written in a Dolphin game ini (`[Gecko]` section) or a bare codes `.txt`.
struct GeckoCodeEntry: Equatable {
  var name: String
  var creator: String
  var notes: [String]
  /// `XXXXXXXX XXXXXXXX` lines, upper-cased.
  var lines: [String]
  /// Listed under `[Gecko_Enabled]` in the same file.
  var isEnabled: Bool

  var codeText: String { lines.joined(separator: "\n") }
  var notesText: String { notes.joined(separator: "\n") }
}

enum GeckoCodeParser {
  /// Parses Dolphin's Gecko format:
  /// ```
  /// [Gecko]
  /// $Name [Creator]
  /// *a note
  /// 0415D3A0 3C008000
  /// [Gecko_Enabled]
  /// $Name
  /// ```
  /// A file with no section headers at all is read whole, as a bare codes list. Codes with no
  /// valid line, and everything outside `[Gecko]` / `[Gecko_Enabled]`, are ignored.
  static func parse(_ text: String) -> [GeckoCodeEntry] {
    let rawLines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    let hasSections = rawLines.contains { $0.hasPrefix("[") && $0.hasSuffix("]") && !$0.hasPrefix("$") }
    var section = hasSections ? "" : "gecko"
    var codes: [GeckoCodeEntry] = []
    var enabledNames: Set<String> = []

    for line in rawLines where !line.isEmpty {
      if line.hasPrefix("["), line.hasSuffix("]") {
        section = line.dropFirst().dropLast().lowercased()
      } else if section == "gecko_enabled" {
        if line.hasPrefix("$") { enabledNames.insert(String(line.dropFirst())) }
      } else if section == "gecko" {
        if line.hasPrefix("$") {
          codes.append(header(String(line.dropFirst())))
        } else if line.hasPrefix("*") {
          if !codes.isEmpty { codes[codes.count - 1].notes.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)) }
        } else if let code = codeLine(line), !codes.isEmpty {
          codes[codes.count - 1].lines.append(code)
        }
      }
    }
    return codes.filter { !$0.lines.isEmpty }.map { entry in
      var entry = entry
      entry.isEnabled = enabledNames.contains(entry.name)
      return entry
    }
  }

  private static func header(_ text: String) -> GeckoCodeEntry {
    var name = text.trimmingCharacters(in: .whitespaces)
    var creator = ""
    if name.hasSuffix("]"), let open = name.lastIndex(of: "[") {
      creator = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
      name = String(name[..<open]).trimmingCharacters(in: .whitespaces)
    }
    return GeckoCodeEntry(name: name, creator: creator, notes: [], lines: [], isEnabled: false)
  }

  private static func codeLine(_ line: String) -> String? {
    let parts = line.split(whereSeparator: \.isWhitespace)
    guard parts.count >= 2, parts[0].count == 8, parts[1].count == 8,
          parts[0].allSatisfy(\.isHexDigit), parts[1].allSatisfy(\.isHexDigit) else { return nil }
    return "\(parts[0]) \(parts[1])".uppercased()
  }
}
