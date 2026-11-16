// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Maps an `https://icube-emu.com/...` universal link onto the equivalent custom-scheme URL, so a web link
/// takes exactly the path `dolphinios://` links already take (`URLRouterService`).
///
/// Pure URL in, URL out. The result is rebuilt from validated parts, never forwarded: whatever else the web
/// link carries (other query items, a fragment) is dropped, and the only value that survives, the game id, is
/// held to a conservative character set. The id is a library lookup key (`DOLLaunchGameByGameID`), not a path,
/// but it is checked anyway.
///
/// Routes, and the ones left out on purpose:
/// - `/play?id=<game id>` becomes `dolphinios://play?id=<game id>`. The path `GameTagPayload.classify` already
///   accepts for NFC tags, so the two agree.
/// - `dsu/add` is not mapped: it writes a controller server into the config the moment it is opened, and a web
///   page can offer a link anyone may tap. `dsu/controller` only means something between two devices. The
///   `EcosystemBridge` routes (`gameinfo`, `requestgame`) answer a caller-chosen app with the library or share
///   game files; they stay custom-scheme only.
///
/// Keep `apple-app-site-association` (docs/app-store) claiming only the paths listed here.
enum UniversalLinkRouter {
  /// The hosts a link may arrive on: the entitled apex, and `www.`, which `GameTagPayload.classify` also accepts.
  static let hosts: Set<String> = [GameTagPayload.ownHost, "www." + GameTagPayload.ownHost]

  /// Path of the play route.
  static let playPath = "/" + GameTagPayload.launchHost

  /// Longest game id accepted. Dolphin ids are 4 to 6 characters; the rest is headroom for homebrew.
  static let maxGameIDLength = 32

  /// What a link asks the app to do.
  enum Route: Equatable {
    case play(gameID: String)
  }

  /// The route a universal link stands for, or nil for anything else: another scheme, host, port or path,
  /// credentials in the URL, or a game id that is missing, repeated or outside the allowed characters.
  static func route(for url: URL) -> Route? {
    guard url.scheme?.lowercased() == "https",
          let host = url.host?.lowercased(), hosts.contains(host),
          url.port == nil, url.user == nil, url.password == nil,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.path.lowercased() == playPath else { return nil }
    let ids = (components.queryItems ?? []).filter { $0.name == GameTagPayload.launchQueryKey }
    guard ids.count == 1, let id = ids[0].value, isValidGameID(id) else { return nil }
    return .play(gameID: id)
  }

  /// The `dolphinios://` URL for a universal link, ready for `ServiceManager.open(url:options:)`; nil when the
  /// link is not one this app serves.
  static func customSchemeURL(for url: URL) -> URL? {
    switch route(for: url) {
    case .play(let gameID)?: return GameTagPayload.launchURL(gameID: gameID)
    case nil: return nil
    }
  }

  /// The same for a web-browsing `NSUserActivity` (cold launch `connectionOptions.userActivities`, or
  /// `scene(_:continue:)` while running). Any other activity type is not ours to answer.
  static func customSchemeURL(for activity: NSUserActivity) -> URL? {
    guard activity.activityType == NSUserActivityTypeBrowsingWeb, let url = activity.webpageURL else { return nil }
    return customSchemeURL(for: url)
  }

  /// ASCII letters, digits, `-` and `_`, 1 to `maxGameIDLength` characters. No `.`, `/`, whitespace or
  /// percent-decoded oddities.
  static func isValidGameID(_ id: String) -> Bool {
    guard (1...maxGameIDLength).contains(id.unicodeScalars.count) else { return false }
    return id.unicodeScalars.allSatisfy { scalar in
      switch scalar.value {
      case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x5F: return true
      default: return false
      }
    }
  }
}
