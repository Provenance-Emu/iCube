// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Settings → Connected Apps: the sibling emulators this app works with
/// (Provenance, iFly), whether each is installed, and how games move between
/// them. Pure: install state in, taps out.
enum ConnectedAppsModelBuilder {
  struct App {
    let id: String
    let name: String
    let icon: String
    let installed: Bool
    /// Opens the app, or the App Store page when it is not installed.
    let open: () -> Void
  }

  /// `scanTag` is nil where NFC tags cannot be read (iPad, tvOS, the simulator); the row is then absent.
  static func make(apps: [App], scanTag: (() -> Void)? = nil) -> MenuModel {
    let rows = apps.map { app in
      SettingsRow.action(app.id, app.name,
                         app.installed ? L("Installed. Tap to open.") : L("Not installed. Tap to get it."),
                         icon: app.icon, badge: app.installed ? L("Installed") : L("Get"), run: app.open)
    }
    return MenuModel(sections: [
      MenuSection(id: "apps", header: L("Apps"),
                  footer: L("Provenance is the hub: its Settings › Connected Apps lists iCube's games and can launch or import them."),
                  items: rows),
      MenuSection(id: "sharing", header: L("Sharing games"), items: [
        SettingsRow.caption("send", L("Long-press a game and choose Send to Provenance. The share sheet hands Provenance a copy of the disc image; it imports on its next scan.")),
        SettingsRow.caption("receive", L("When Provenance asks for a game, iCube asks you first, then offers the file the same way.")),
      ]),
    ] + tagSection(scanTag: scanTag))
  }

  /// Tap-to-play tags: one tag format across iCube, Provenance and iFly; each app launches its own.
  private static func tagSection(scanTag: (() -> Void)?) -> [MenuSection] {
    guard let scanTag else { return [] }
    return [MenuSection(id: "tags", header: L("NFC tags"),
                        footer: L("Long-press a game and choose Write to NFC Tag. Tapping the tag with your iPhone launches the game; a tag written by Provenance or iFly opens there instead."),
                        items: [
      SettingsRow.action("scan-tag", L("Scan NFC Tag"), L("Read a game tag now and launch its game."), icon: "wave.3.right.circle", run: scanTag),
    ])]
  }
}
