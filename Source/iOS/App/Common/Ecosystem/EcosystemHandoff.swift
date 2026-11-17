// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The drop box Provenance, iFly and iCube share on one device.
///
/// All three apps are entitled to the App Group `group.org.provenance-emu.provenance`.
/// Its container is the only storage they can all reach, so it carries games
/// (and later saves) from one app to another without a network connection and
/// without the sender staying alive: the sender clones the files in, the
/// receiver picks them up whenever it next runs.
///
/// Layout, under `<group container>/Ecosystem/`:
///
///     Apps/<scheme>.json                  EcosystemPresence, one per app
///     Handoff/<recipient scheme>/<id>/    one hand-off, complete
///         manifest.json                   EcosystemHandoffManifest
///         files/<relative path>           the files, layout preserved
///     Handoff/<recipient scheme>/.<id>.staging/   a hand-off still being written
///
/// Rules every app follows:
///
/// - **Presence.** On launch and on every return to the foreground an app
///   rewrites `Apps/<its scheme>.json`. `handoff` is the highest hand-off
///   version it receives (0 or absent: none).
/// - **Send.** Only to a peer whose presence says `handoff >= 1` and lists the
///   kind in `accepts`. Write into `.<id>.staging`, then rename it to `<id>`:
///   a receiver never sees a half-written hand-off. Then open
///   `<recipient scheme>://handoff?id=<id>&from=<own scheme>` to bring the
///   receiver forward. The open is a courtesy; a receiver that is not opened
///   still finds the hand-off on its own.
/// - **Receive.** On launch, on foreground and on the `handoff` URL, take every
///   non-hidden directory in `Handoff/<own scheme>/` whose manifest it
///   understands, move the files into its own library, then delete the
///   directory. A manifest with a newer `version` or an unknown `kind` is left
///   alone.
/// - **Clean up.** A sender removes its own hand-offs that nobody picked up
///   after `staleAfter`, and staging directories older than `stagingStaleAfter`.
///
/// Scheme names are the directory names, lowercased: `provenance`, `ifly`,
/// `dolphinios` (iCube).
///
/// This is version 1 of a contract the three apps share; iFly's
/// `EcosystemHandoff.swift` carries the same text. Change it in all three or
/// not at all.
enum EcosystemHandoff {
  /// The App Group all three apps carry. Not `ICubeSnapshot`'s group, which
  /// only iCube and its own extensions are in.
  static let appGroupID = "group.org.provenance-emu.provenance"

  /// Hand-off version this build writes and reads.
  static let protocolVersion = 1

  /// The hand-off kind for a game's file set. The only kind in version 1.
  static let gameKind = "game"

  /// Systems iCube can take, as hand-off system ids (`systemID(for:)`).
  static let acceptedSystems = ["gamecube", "wii"]

  static let manifestName = "manifest.json"
  static let filesDirectoryName = "files"
  static let stagingSuffix = ".staging"

  /// Host of the wake-up URL: `<scheme>://handoff?id=<id>&from=<scheme>`.
  static let urlHost = "handoff"

  /// A hand-off nobody picked up is removed by its sender after this long.
  static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

  /// A staging directory this old belongs to a send that died.
  static let stagingStaleAfter: TimeInterval = 60 * 60

  /// `<group container>/Ecosystem`, or nil when this build has no access to
  /// the group (unsigned simulator run, a sideload signed without it).
  static var sharedRoot: URL? {
    guard let container = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
    #if targetEnvironment(macCatalyst)
    // macOS hands back a URL even for a group this build is not in.
    guard FileManager.default.isWritableFile(atPath: container.path) else { return nil }
    #endif
    return container.appendingPathComponent("Ecosystem", isDirectory: true)
  }

  /// `Handoff/<scheme>/`: where hand-offs addressed to `scheme` wait.
  static func inbox(for scheme: String, root: URL) -> URL {
    root.appendingPathComponent("Handoff", isDirectory: true)
      .appendingPathComponent(scheme.lowercased(), isDirectory: true)
  }

  /// `Apps/<scheme>.json`.
  static func presenceURL(for scheme: String, root: URL) -> URL {
    root.appendingPathComponent("Apps", isDirectory: true)
      .appendingPathComponent(scheme.lowercased())
      .appendingPathExtension("json")
  }

  /// The URL that brings a receiver forward to import hand-off `id`.
  static func wakeURL(to scheme: String, id: String, from: String = EcosystemSchemes.ownScheme) -> URL? {
    var components = URLComponents()
    components.scheme = scheme
    components.host = urlHost
    components.queryItems = [
      URLQueryItem(name: "id", value: id),
      URLQueryItem(name: "from", value: from),
    ]
    return components.url
  }

  /// The hand-off system id for one of this library's platforms, or nil when
  /// there is no id a sibling would know (Triforce, a bare ELF/DOL): the
  /// manifest's `system` is a hint and may be absent. WiiWare titles are Wii
  /// software.
  static func systemID(for platform: LibraryPlatform) -> String? {
    switch platform {
    case .gamecube: "gamecube"
    case .wii, .wiiware: "wii"
    case .triforce, .elfdol, .unknown: nil
    }
  }
}
