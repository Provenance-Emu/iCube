// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// `manifest.json` of one hand-off in the shared drop box (see `EcosystemHandoff`).
///
/// Field names are the wire format shared with Provenance and iFly. `kind` and
/// each file's `role` are plain strings so a manifest written by a newer app
/// still decodes here; a receiver checks `version` and `kind` before acting.
struct EcosystemHandoffManifest: Codable, Equatable, Sendable {
  struct File: Codable, Equatable, Sendable {
    /// Path below `files/`, forward slashes, never absolute, no `..`.
    var path: String
    /// `primaryRole` for a file the receiver adds to its library (a disc
    /// image); `companionRole` for a file one of those needs beside it.
    var role: String
    var size: Int64
  }

  static let primaryRole = "primary"
  static let companionRole = "companion"

  var version: Int
  /// Also the hand-off's directory name.
  var id: String
  /// Sender's scheme.
  var from: String
  /// Recipient's scheme.
  var to: String
  var created: Date
  var kind: String
  /// Display title, for the receiver's messages.
  var title: String
  /// System id as the sender knows it ("gamecube", "wii"…), a hint only.
  var system: String?
  /// Lowercase MD5 of the primary file as the sender's library has it.
  var md5: String?
  var files: [File]

  static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
