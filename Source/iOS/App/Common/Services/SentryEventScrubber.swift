// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// App Store builds send crash and performance data "not linked to you": no game identity and no file paths
/// (a ROM's file name is a game title). Pure, so the rules are unit-tested.
enum SentryEventScrubber {
  static let strippedTags: Set<String> = ["game_id", "game_title"]

  /// Extensions that end a path: everything the library imports or browses (`ImportableFileTypes`), plus the
  /// save, config and data files the app reads. `nkit.iso` ends in `iso`.
  private static let pathExtensions = ImportableFileTypes.webDAVBrowsableExtensions
    .union(["sav", "gci", "raw", "json", "ini"])
    .sorted()
    .joined(separator: "|")

  /// A path runs from its root (`/var/mobile`, `/private/var/mobile` or `/Users`, optionally behind `file://`)
  /// to the first known file extension that ends a word (a sentence's closing period counts), case-insensitively, because game file names contain
  /// spaces, dots and version numbers ("Foo v1.02 Collector's Edition.iso"). With no such extension it takes
  /// the rest of the line.
  private static let pathPattern: NSRegularExpression = {
    let end = #"(?:\.(?:"# + pathExtensions + #")(?=$|[\s:;,)\]"'?#]|\.(?:\s|$))|$)"#
    let pattern = #"(?:file://)?(?:(?:/private)?/var/mobile|/Users)/[^\n]*?"# + end
    // The pattern is built from constants, so failing to compile is a programmer error.
    return try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .caseInsensitive])
  }()

  static func scrubTags(_ tags: [String: String]) -> [String: String] {
    tags.filter { !strippedTags.contains($0.key) }
  }

  static func scrubMessage(_ text: String) -> String {
    let range = NSRange(text.startIndex..., in: text)
    return pathPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "<path>")
  }
}
