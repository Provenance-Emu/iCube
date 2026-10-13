// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Settings → Privacy. One switch today: crash and performance reports to Sentry (on by default, App Store
/// privacy label: "Diagnostics, not linked to you"). Pure: the value in, the change out.
enum ConfigPrivacyModelBuilder {
  static func make(crashReports: Bool, apply: @escaping (Bool) -> Void) -> MenuModel {
    MenuModel(sections: [
      MenuSection(id: "diagnostics", header: L("Diagnostics"), items: [
        SettingsRow.toggle("crash-reports", L("Share Crash Reports"), crashReports,
                           L("Sends crash and performance reports to the iCube developers. Reports never include your games, file names or personal data."),
                           set: apply),
      ]),
    ])
  }
}
