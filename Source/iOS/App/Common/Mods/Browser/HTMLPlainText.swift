// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Turns the HTML in a GameBanana description into plain text. A hand-rolled stripper rather than
/// `NSAttributedString(html:)`, which runs WebKit on the main thread and fetches `<img>` URLs.
enum HTMLPlainText {
  private static let blockTags = ["p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol"]
  private static let namedEntities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                                      "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}",
                                      "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}"]

  static func text(from html: String) -> String {
    var output = ""
    var index = html.startIndex
    var skippingUntilClose: String?
    while index < html.endIndex {
      let character = html[index]
      if character == "<", let close = html[index...].firstIndex(of: ">") {
        let tag = String(html[html.index(after: index)..<close])
        handle(tag: tag, output: &output, skippingUntilClose: &skippingUntilClose)
        index = html.index(after: close)
      } else if skippingUntilClose != nil {
        index = html.index(after: index)
      } else if character == "&", let end = html[index...].prefix(12).firstIndex(of: ";"),
                let decoded = decode(entity: String(html[html.index(after: index)..<end])) {
        output.append(decoded)
        index = html.index(after: end)
      } else {
        output.append(character)
        index = html.index(after: index)
      }
    }
    return collapse(output)
  }

  private static func handle(tag rawTag: String, output: inout String, skippingUntilClose: inout String?) {
    let isClosing = rawTag.hasPrefix("/")
    let name = rawTag.drop { $0 == "/" }.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()
    if let skipped = skippingUntilClose {
      if isClosing && name == skipped { skippingUntilClose = nil }
      return
    }
    if !isClosing && (name == "script" || name == "style") {
      skippingUntilClose = name
    } else if name == "br" {
      output.append("\n")
    } else if blockTags.contains(name), !output.hasSuffix("\n") {
      output.append("\n")
    }
  }

  private static func decode(entity: String) -> String? {
    if let named = namedEntities[entity] { return named }
    guard entity.hasPrefix("#") else { return nil }
    let digits = entity.dropFirst()
    let value = digits.hasPrefix("x") || digits.hasPrefix("X") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
    return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
  }

  /// Trims each line, and keeps at most one blank line in a row.
  private static func collapse(_ text: String) -> String {
    var lines: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty && (lines.last?.isEmpty ?? true) { continue }
      lines.append(trimmed)
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
