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
    // Explicit user intent: re-arm the handshake even if a previous attempt died on the brk.
    JitManager.shared().clearTXMHandshakeCookie()
    UIApplication.shared.open(url, options: [:], completionHandler: nil)
    return true
    #else
    return false
    #endif
  }

  /// Builds `stikdebug://enable-jit?bundle-id=…&pid=…&script-name=icube.js&script-data=<base64url>`.
  ///
  /// `pid` is REQUIRED and its absence is not a soft failure. StikDebug's integration guide says
  /// to always send the bundle id together with the current pid: with a pid it calls
  /// `debugApp(withPID:)` and attaches to the process that is already running, and without one it
  /// falls back to `debugApp(withBundleID:)`, which goes through `process_control_launch_app()`
  /// and expects an integer pid back in the launch response. For an app that is ALREADY running --
  /// which iCube always is, since it is the thing opening the URL -- that path fails with
  /// `UnexpectedResponse("expected integer PID in launch app response")` and no debugger is ever
  /// attached. Observed here as: the deep link opens, iCube is relaunched, and it comes back with
  /// `debugger_attached = false`, so the brk handshake never runs and the user silently lands on
  /// the interpreter. Same fix as intraducine/iridium#29.
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
      "\(scheme)://enable-jit?bundle-id=\(safeBundleID)&pid=\(getpid())"
      + "&script-name=\(scriptResource).js&script-data=\(encodedScript)")
  }

  /// Standard base64url (RFC 4648 §5): `+`→`-`, `/`→`_`, padding stripped.
  private static func base64URLEncodedNoPadding(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
