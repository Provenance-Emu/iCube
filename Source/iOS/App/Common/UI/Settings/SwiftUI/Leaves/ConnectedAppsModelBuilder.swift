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

  static func make(apps: [App]) -> MenuModel {
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
    ])
  }
}
