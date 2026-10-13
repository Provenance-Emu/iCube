// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// App Store builds send crash and performance data "not linked to you": no game identity and no file paths
/// (a ROM's file name is a game title). Pure, so the rules are unit-tested.
enum SentryEventScrubber {
  static let strippedTags: Set<String> = ["game_id", "game_title"]

  /// A path runs from its root to the file extension that ends it, because game file names contain spaces
  /// ("Super Smash Bros. Melee.iso"). With no extension in sight it takes the rest of the line.
  private static let pathEnd = #"(?:\.[A-Za-z0-9]{2,5}(?=$|[\s:;,)\]"'])|$)"#
  private static let pathPattern = try! NSRegularExpression(
    pattern: #"(?:/private)?/var/mobile/[^\n]*?"# + pathEnd + #"|/Users/[^\n]*?"# + pathEnd,
    options: .anchorsMatchLines)

  static func scrubTags(_ tags: [String: String]) -> [String: String] {
    tags.filter { !strippedTags.contains($0.key) }
  }

  static func scrubMessage(_ text: String) -> String {
    let range = NSRange(text.startIndex..., in: text)
    return pathPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "<path>")
  }
}
