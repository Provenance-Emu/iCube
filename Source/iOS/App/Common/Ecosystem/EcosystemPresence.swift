// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// `Apps/<scheme>.json` in the shared drop box: what one app tells its siblings
/// about itself (see `EcosystemHandoff`). A sender reads the recipient's file
/// to decide between a direct hand-off and the share sheet.
struct EcosystemPresence: Codable, Equatable, Sendable {
  var version: Int
  var scheme: String
  var bundleID: String
  var appVersion: String
  var build: String
  /// Highest hand-off version this app receives. 0: it does not receive.
  var handoff: Int
  /// Hand-off kinds it receives.
  var accepts: [String]
  /// System ids it takes games for. Empty: any system.
  var systems: [String]
  var updated: Date

  /// Can this app take a hand-off of `kind` for `system` from this build?
  /// A game with no system id (`system` nil) is not held back by the list.
  func accepts(kind: String, system: String?) -> Bool {
    guard handoff >= 1, accepts.contains(kind) else { return false }
    if let system, !systems.isEmpty {
      return systems.contains(system)
    }
    return true
  }

  /// iCube's own entry.
  static func own(now: Date = Date(), bundle: Bundle = .main) -> EcosystemPresence {
    let info = bundle.infoDictionary ?? [:]
    return EcosystemPresence(
      version: EcosystemHandoff.protocolVersion,
      scheme: EcosystemSchemes.ownScheme,
      bundleID: bundle.bundleIdentifier ?? "",
      appVersion: info["CFBundleShortVersionString"] as? String ?? "",
      build: info["CFBundleVersion"] as? String ?? "",
      handoff: EcosystemHandoff.protocolVersion,
      accepts: [EcosystemHandoff.gameKind],
      systems: EcosystemHandoff.acceptedSystems,
      updated: now
    )
  }

  /// The entry `scheme` last wrote, or nil when it never has (not installed,
  /// or a build from before the drop box).
  static func read(scheme: String, root: URL) -> EcosystemPresence? {
    let url = EcosystemHandoff.presenceURL(for: scheme, root: root)
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? EcosystemHandoffManifest.decoder().decode(EcosystemPresence.self, from: data)
  }

  func write(root: URL, fileManager: FileManager = .default) throws {
    let url = EcosystemHandoff.presenceURL(for: scheme, root: root)
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try EcosystemHandoffManifest.encoder().encode(self).write(to: url, options: .atomic)
  }
}
