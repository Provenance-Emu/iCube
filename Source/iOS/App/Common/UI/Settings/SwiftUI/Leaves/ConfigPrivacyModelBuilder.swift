// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Settings → Privacy. One switch today: crash and performance reports to Sentry (on by default, App Store
/// privacy label: "Diagnostics, not linked to you"). Pure: the value in, the change out.
enum ConfigPrivacyModelBuilder {
  /// Only the App Store build strips game ids and file paths from reports, so only it may promise that.
  static var crashReportsFooter: String {
    #if APPSTORE
    L("Sends crash and performance reports to the iCube developers. Reports never include your games, file names or personal data.")
    #else
    L("Sends crash and performance reports to the iCube developers. Reports can include the ID of the game you were playing.")
    #endif
  }

  static func make(crashReports: Bool, apply: @escaping (Bool) -> Void) -> MenuModel {
    MenuModel(sections: [
      MenuSection(id: "diagnostics", header: L("Diagnostics"), items: [
        SettingsRow.toggle("crash-reports", L("Share Crash Reports"), crashReports,
                           crashReportsFooter,
                           set: apply),
      ]),
    ])
  }
}
