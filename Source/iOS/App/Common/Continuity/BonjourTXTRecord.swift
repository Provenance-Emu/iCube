// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Reads a Bonjour TXT record without `NetService.dictionary(fromTXTRecord:)`.
///
/// Foundation returns NSNull for a key that has no `=`, and Swift traps bridging that to
/// `[String: Data]`. Any device on the network can advertise such a record, so the app crashed
/// while browsing (ICUBE-NH).
enum BonjourTXTRecord {
  /// Keys with a value, as their raw bytes. A key without `=` is left out, an empty value is kept,
  /// and the first of a repeated key wins (RFC 6763, section 6.4). A record that ends early is
  /// read as far as it goes.
  static func dictionary(from data: Data) -> [String: Data] {
    var result: [String: Data] = [:]
    var index = data.startIndex
    while index < data.endIndex {
      let length = Int(data[index])
      index += 1
      guard index + length <= data.endIndex else { break }
      let entry = data[index ..< (index + length)]
      index += length
      guard let equals = entry.firstIndex(of: UInt8(ascii: "=")), equals > entry.startIndex,
            let key = String(data: entry[..<equals], encoding: .utf8), result[key] == nil
      else { continue }
      result[key] = Data(entry[(equals + 1)...])
    }
    return result
  }
}
