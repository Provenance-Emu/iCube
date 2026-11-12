// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One key a port's controller reads from a profile, and what its value is
/// (`TVControllerMappingBridge.profileKeys`): the linter's and the completion list's vocabulary.
struct ProfileKey: Equatable {
  enum Kind: Equatable {
    /// `Device = MFi/0/DualSense Wireless Controller`.
    case device
    /// A control's binding: an expression (`` `Button A` | `Button B` ``).
    case control
    /// An output's binding (`Rumble/Motor`): an expression naming the device's outputs.
    case output
    /// A number, or an expression that yields one.
    case number
    /// `True` / `False`, or an expression.
    case toggle
    /// One of a few names (`Extension = Nunchuk`), or an expression.
    case choice([String])
  }

  let name: String
  let kind: Kind
}

/// One line of a profile's text. Ranges are UTF-16 offsets into the whole text, which is what
/// `UITextView` and `NSAttributedString` count in.
struct ProfileTextLine: Equatable {
  enum Content: Equatable {
    case blank
    /// `# …`: the only comment the core's INI reader knows (IniFile.cpp `ParseLine`).
    case comment
    case section(String)
    case entry(key: String, value: String, keyRange: NSRange, valueRange: NSRange, equalsLocation: Int)
    /// Neither a comment, a section nor `Key = Value`: the core drops it without a word.
    case malformed
  }

  /// 1-based.
  let number: Int
  /// The line without its line break.
  let range: NSRange
  let content: Content
}

/// A controller profile as text: the `[Profile]` section of the files under `Config/Profiles`, the
/// form Dolphin's desktop builds and every guide on the web use. Pure; the editor reads and writes
/// the live mapping through `ProfileTextIO`.
enum ProfileTextDocument {
  static let sectionName = "Profile"
  static let sectionHeader = "[Profile]"

  static func lines(of text: String) -> [ProfileTextLine] {
    let ns = text as NSString
    var lines: [ProfileTextLine] = []
    var location = 0
    var number = 1
    while location <= ns.length {
      var end = location
      while end < ns.length, ns.character(at: end) != lineFeed { end += 1 }
      var contentEnd = end
      if contentEnd > location, ns.character(at: contentEnd - 1) == carriageReturn { contentEnd -= 1 }
      let range = NSRange(location: location, length: contentEnd - location)
      lines.append(ProfileTextLine(number: number, range: range, content: content(of: range, in: ns)))
      if end >= ns.length { break }
      location = end + 1
      number += 1
    }
    return lines
  }

  /// The text as the core must be given it: the entries under a `[Profile]` header. A paste of bare
  /// `Key = Value` lines (what forum posts usually are) gets the header it lacks.
  static func normalized(_ text: String) -> String {
    let hasHeader = lines(of: text).contains {
      if case .section(let name) = $0.content { return name == sectionName }
      return false
    }
    let body = text.hasSuffix("\n") ? text : text + "\n"
    return hasHeader ? body : sectionHeader + "\n" + body
  }

  // MARK: Line parsing

  private static let lineFeed: unichar = 0x0A
  private static let carriageReturn: unichar = 0x0D
  private static let space: unichar = 0x20
  private static let tab: unichar = 0x09
  private static let hash: unichar = 0x23
  private static let openBracket: unichar = 0x5B
  private static let closeBracket: unichar = 0x5D
  private static let equals: unichar = 0x3D

  private static func isBlank(_ character: unichar) -> Bool { character == space || character == tab }

  /// `range` without leading and trailing spaces and tabs.
  static func trimmed(_ range: NSRange, in ns: NSString) -> NSRange {
    var start = range.location
    var end = range.location + range.length
    while start < end, isBlank(ns.character(at: start)) { start += 1 }
    while end > start, isBlank(ns.character(at: end - 1)) { end -= 1 }
    return NSRange(location: start, length: end - start)
  }

  private static func content(of line: NSRange, in ns: NSString) -> ProfileTextLine.Content {
    let body = trimmed(line, in: ns)
    guard body.length > 0 else { return .blank }
    let first = ns.character(at: body.location)
    if first == hash { return .comment }
    if first == openBracket {
      let close = ns.range(of: "]", options: [], range: body)
      guard close.location != NSNotFound else { return .malformed }
      let name = NSRange(location: body.location + 1, length: close.location - body.location - 1)
      return .section(ns.substring(with: name))
    }
    var equalsLocation = body.location
    while equalsLocation < body.location + body.length, ns.character(at: equalsLocation) != equals { equalsLocation += 1 }
    guard equalsLocation < body.location + body.length else { return .malformed }
    let keyRange = trimmed(NSRange(location: body.location, length: equalsLocation - body.location), in: ns)
    guard keyRange.length > 0 else { return .malformed }
    let afterEquals = equalsLocation + 1
    let valueRange = trimmed(NSRange(location: afterEquals, length: body.location + body.length - afterEquals), in: ns)
    return .entry(
      key: ns.substring(with: keyRange), value: ns.substring(with: valueRange),
      keyRange: keyRange, valueRange: valueRange, equalsLocation: equalsLocation)
  }
}
