// Copyright 2024 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
#if os(iOS)
import UIKit
#endif

/// Bridges iCube to StikDebug's `enable-jit` URL scheme so the app can hand StikDebug its own
/// bundled JIT broker script (`icube.js`) at runtime, instead of relying on the user pre-assigning
/// a script in StikDebug's Scripts tab or on StikDebug's hardcoded per-app-name auto-assignment
/// (which iCube's display name is not in). This is the only StikDebug path that lets a target app
/// ship its own broker logic; StikDebug never reads scripts from the target app's bundle directly.
///
/// iOS only: StikDebug does not exist on tvOS, so every entry point is a no-op there.
enum StikDebugLauncher {
  /// StikDebug's primary custom URL scheme. The app also registers the legacy `stikjit` scheme.
  private static let scheme = "stikdebug"

  /// Bundled broker script (`icube.js`) that answers iCube's `brk #0x69` TXM handshake with
  /// `prepare_memory_region`, authorizing the dual-mapped JIT region on the first handshake.
  private static let scriptResource = "icube"

  /// True when StikDebug is installed and reachable via its URL scheme. Always false on tvOS.
  static var isStikDebugInstalled: Bool {
    #if os(iOS)
    guard let url = URL(string: "\(scheme)://") else { return false }
    return UIApplication.shared.canOpenURL(url)
    #else
    return false
    #endif
  }

  /// Hands the bundled broker script to StikDebug and requests JIT for this app. StikDebug attaches
  /// `debugserver`, runs the script to authorize the JIT region, then relaunches iCube. Returns
  /// false (no-op) on tvOS, when StikDebug isn't installed, or when the deep link can't be built.
  @discardableResult
  static func enableJIT() -> Bool {
    #if os(iOS)
    guard let bundleID = Bundle.main.bundleIdentifier,
          let url = makeEnableJITURL(bundleID: bundleID),
          UIApplication.shared.canOpenURL(url) else {
      return false
    }
    UIApplication.shared.open(url, options: [:], completionHandler: nil)
    return true
    #else
    return false
    #endif
  }

  /// Builds `stikdebug://enable-jit?bundle-id=…&script-name=icube.js&script-data=<base64url>`.
  /// The script is base64url-encoded without padding: StikDebug decodes `script-data` twice (once
  /// via `URLComponents.queryItems`, again via `removingPercentEncoding`), and the base64url
  /// alphabet (`A–Z a–z 0–9 - _`) contains no percent-escapable characters, so it survives intact.
  static func makeEnableJITURL(bundleID: String) -> URL? {
    guard let scriptURL = Bundle.main.url(forResource: scriptResource, withExtension: "js"),
          let scriptData = try? Data(contentsOf: scriptURL) else {
      return nil
    }
    let encodedScript = base64URLEncodedNoPadding(scriptData)
    let allowed = CharacterSet(charactersIn:
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
    let safeBundleID = bundleID.addingPercentEncoding(withAllowedCharacters: allowed) ?? bundleID
    return URL(string:
      "\(scheme)://enable-jit?bundle-id=\(safeBundleID)&script-name=\(scriptResource).js&script-data=\(encodedScript)")
  }

  /// Standard base64url (RFC 4648 §5): `+`→`-`, `/`→`_`, padding stripped.
  private static func base64URLEncodedNoPadding(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
