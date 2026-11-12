// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One thing the completion strip offers: what it shows, and what tapping it writes over `range`.
struct ProfileCompletion: Equatable, Identifiable {
  let title: String
  let insertion: String
  /// The typed fragment the insertion replaces (UTF-16, in the whole text).
  let range: NSRange

  var id: String { title }
}

/// What can go where the cursor is. Left of `=`: the port's keys. Right of it, on a control's line:
/// the device's inputs (backticked, as the parser wants them) and the expression functions.
/// Pure; the editor renders the list as a strip above the keyboard, because a phone keyboard has no
/// backtick within two taps and input names have to match to the letter.
enum ProfileTextCompletion {
  static let limit = 12

  static func suggestions(text: String, cursor: Int, keys allKeys: [ProfileKey], inputs: [String]) -> [ProfileCompletion] {
    let ns = text as NSString
    guard cursor >= 0, cursor <= ns.length else { return [] }
    let lines = ProfileTextDocument.lines(of: text)
    guard let line = lines.first(where: { cursor >= $0.range.location && cursor <= $0.range.location + $0.range.length })
    else { return [] }
    // A key the text already sets is not offered again (setting it twice is a lint warning).
    let present = Set(lines.compactMap { other -> String? in
      guard other.number != line.number, case .entry(let key, _, _, _, _) = other.content else { return nil }
      return key
    })
    let keys = allKeys.filter { !present.contains($0.name) }
    switch line.content {
    case .comment, .section:
      return []
    case .blank, .malformed:
      return keyCompletions(line: line.range, cursor: cursor, ns: ns, keys: keys, writesEquals: true)
    case .entry(let key, _, _, let valueRange, let equalsLocation):
      if cursor <= equalsLocation {
        // The line already has its `=`: only the key is rewritten.
        let keyPart = NSRange(location: line.range.location, length: equalsLocation - line.range.location)
        return keyCompletions(line: keyPart, cursor: cursor, ns: ns, keys: keys, writesEquals: false)
      }
      guard let kind = allKeys.first(where: { $0.name == key })?.kind else { return [] }
      return valueCompletions(kind: kind, valueRange: valueRange, cursor: cursor, ns: ns, inputs: inputs)
    }
  }

  // MARK: Keys

  /// Keys containing what is typed from the line's start to the cursor, those that begin with it
  /// first. Choosing one replaces the fragment with `Key = ` (or `Key ` before an `=` already there).
  private static func keyCompletions(line: NSRange, cursor: Int, ns: NSString, keys: [ProfileKey], writesEquals: Bool) -> [ProfileCompletion] {
    let typed = ProfileTextDocument.trimmed(NSRange(location: line.location, length: max(0, cursor - line.location)), in: ns)
    let fragment = ns.substring(with: typed)
    let replace = NSRange(location: typed.location, length: line.location + line.length - typed.location)
    return ranked(keys.map(\.name), by: fragment).map {
      ProfileCompletion(title: $0, insertion: $0 + (writesEquals ? " = " : " "), range: replace)
    }
  }

  // MARK: Values

  private static let backtick: unichar = 0x60

  private static func valueCompletions(kind: ProfileKey.Kind, valueRange: NSRange, cursor: Int, ns: NSString, inputs: [String]) -> [ProfileCompletion] {
    switch kind {
    case .device, .output:
      return []
    case .toggle:
      return ProfileExpressionSyntax.booleans.map { ProfileCompletion(title: $0, insertion: $0, range: valueRange) }
    case .choice(let choices):
      return choices.map { ProfileCompletion(title: $0, insertion: $0, range: valueRange) }
    case .control, .number:
      break
    }
    // An open backtick before the cursor: complete the input name it started.
    var backticks = 0
    var lastBacktick = NSNotFound
    var index = valueRange.location
    while index < cursor, index < ns.length {
      if ns.character(at: index) == backtick {
        backticks += 1
        lastBacktick = index
      }
      index += 1
    }
    if backticks % 2 == 1 {
      let fragment = ns.substring(with: NSRange(location: lastBacktick + 1, length: cursor - lastBacktick - 1))
      // Replace through the closing backtick when the name is already closed.
      var end = cursor
      while end < valueRange.location + valueRange.length, ns.character(at: end) != backtick { end += 1 }
      if end < valueRange.location + valueRange.length { end += 1 }
      let replace = NSRange(location: lastBacktick, length: end - lastBacktick)
      return ranked(inputs, by: fragment).map { ProfileCompletion(title: $0, insertion: "`\($0)`", range: replace) }
    }
    // Otherwise the word under the cursor: a function, or an input typed without its backtick.
    var start = cursor
    while start > valueRange.location, isWord(ns.character(at: start - 1)) { start -= 1 }
    let fragment = ns.substring(with: NSRange(location: start, length: cursor - start))
    let replace = NSRange(location: start, length: cursor - start)
    let functions = fragment.isEmpty ? [] : ProfileExpressionSyntax.functions.filter { $0.hasPrefix(fragment.lowercased()) }
    let inputMatches = kind == .control ? ranked(inputs, by: fragment) : []
    let all = functions.map { ProfileCompletion(title: $0 + "(", insertion: $0 + "(", range: replace) }
      + inputMatches.map { ProfileCompletion(title: $0, insertion: "`\($0)`", range: replace) }
    return Array(all.prefix(limit))
  }

  private static func isWord(_ c: unichar) -> Bool {
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F
  }

  /// Case-insensitive: names that begin with the fragment, then names that contain it, each in the
  /// order given (the controller's own). Everything, in order, for an empty fragment.
  static func ranked(_ names: [String], by fragment: String) -> [String] {
    guard !fragment.isEmpty else { return Array(names.prefix(limit)) }
    let needle = fragment.lowercased()
    let beginning = names.filter { $0.lowercased().hasPrefix(needle) }
    let containing = names.filter { !$0.lowercased().hasPrefix(needle) && $0.lowercased().contains(needle) }
    return Array((beginning + containing).prefix(limit))
  }
}
