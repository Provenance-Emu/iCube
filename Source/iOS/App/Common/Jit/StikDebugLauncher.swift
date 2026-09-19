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

  /// StikDebug's own bundled TXM broker script. Not ours: see makeEnableJITURL for why we stopped
  /// shipping `icube.js` through the URL.
  private static let brokerScript = "universal.js"

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

  /// Builds `stikdebug://enable-jit?bundle-id=…&pid=…&script-name=universal.js`.
  ///
  /// `pid` is REQUIRED and its absence is not a soft failure. StikDebug's integration guide says
  /// to always send the bundle id together with the current pid: with a pid it calls
  /// `debugApp(withPID:)` and attaches to the process that is already running, and without one it
  /// falls back to `debugApp(withBundleID:)`, which goes through `process_control_launch_app()`
  /// and expects an integer pid back in the launch response. For an app that is ALREADY running --
  /// which iCube always is, since it is the thing opening the URL -- that path fails with
  /// `UnexpectedResponse("expected integer PID in launch app response")`.
  /// Same fix as intraducine/iridium#29.
  ///
  /// We ask for StikDebug's OWN bundled `universal.js` rather than shipping `icube.js` inline.
  /// Handing over a custom script meant base64-ing ~3.5 KB of JavaScript into a URL and hoping
  /// every layer between here and StikDebug's parser preserved it: the URL length, the encoding
  /// (their guide specifies standard base64, this shipped base64url), and StikDebug's own
  /// double-decode. Measured on an iPhone 16 Pro Max, iOS 26.6.2, that hand-off silently attached
  /// nothing -- iCube went away for ~65 s and came back with `debugger_attached = false` -- with
  /// no error the user could see. `universal.js` removes the entire transport: the URL is a few
  /// dozen bytes and the script is one StikDebug already trusts.
  ///
  /// It is protocol-compatible with us. `MemoryUtil_iOS_LuckTXM.cpp` leads with `brk #0x69`,
  /// which `universal.js` cleanly REJECTS by writing the sentinel `0xE0000069` into x0 without
  /// preparing the region, and we then migrate to `brk #0xf00d` with x16 = 1 (CMD_PREPARE_REGION)
  /// and x16 = 0 (CMD_DETACH), which is exactly what that script implements.
  static func makeEnableJITURL(bundleID: String) -> URL? {
    let allowed = CharacterSet(charactersIn:
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
    let safeBundleID = bundleID.addingPercentEncoding(withAllowedCharacters: allowed) ?? bundleID
    return URL(string:
      "\(scheme)://enable-jit?bundle-id=\(safeBundleID)&pid=\(getpid())"
      + "&script-name=\(brokerScript)")
  }

}
