// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What the tvOS Add Games screen shows for the upload server. Platform-neutral so the iOS test target
/// covers it.
struct AddGamesServerState: Equatable {
  enum Status: Equatable {
    /// The screen asked for the server (`PVWebServerUserAccessRequested`) and it is not listening yet.
    case starting
    case running
  }

  let status: Status
  /// The browser upload page. Nil until the server is listening and has a LAN address.
  let uploadURL: String?
  /// The Finder / WebDAV address, only when it differs from `uploadURL`. Today both share one listener.
  let webDavURL: String?

  /// The QR code encodes the browser URL: that is what a phone camera opens.
  var qrPayload: String? { uploadURL }

  static func make(isRunning: Bool, webURL: String?, webDavURL: String?) -> AddGamesServerState {
    let web = nonEmpty(webURL)
    let dav = nonEmpty(webDavURL)
    return AddGamesServerState(
      status: isRunning ? .running : .starting,
      uploadURL: isRunning ? web ?? dav : nil,
      webDavURL: isRunning && web != nil && dav != web ? dav : nil
    )
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
  }
}
