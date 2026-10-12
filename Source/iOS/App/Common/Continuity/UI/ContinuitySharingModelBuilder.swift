// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import PVContinuity
import SwiftUI

struct ContinuityGrantRowSummary: Equatable {
  let peerId: String
  let name: String
  let grantTitle: String
}

/// Pure: Share My Library and one device's grant, as rows.
enum ContinuitySharingModelBuilder {
  static func make(sharesLibrary: Bool, grants: [ContinuityGrantRowSummary], excluded: [(gameID: String, title: String)],
                   grantDetail: @escaping (String, String) -> AnyView,
                   setShares: @escaping (Bool) -> Void, shareAgain: @escaping (String) -> Void) -> MenuModel {
    let share = MenuSection(
      id: "share", header: L("Share This Library"),
      footer: L("When this is on, devices you've paired with can browse this device's games and copy them. Only the game is sent — never your saves, memory cards or Wii save data."),
      items: [SettingsRow.toggle("share", L("Share My Library"), sharesLibrary, L("Serve this device's game list to paired devices."),
                                 icon: "square.stack.3d.up", set: setShares)])
    let grantRows: [MenuItem] = grants.map { g in
      var item = SettingsRow.destination("grant-\(g.peerId)", g.name, L("What this device may do with your library."),
                                         icon: "ipad.and.iphone", view: grantDetail(g.peerId, g.name))
      item.subtitle = g.grantTitle
      return item
    }
    let paired = MenuSection(
      id: "paired", header: L("Paired Devices"),
      footer: L("\"Ask Every Time\" prompts you when a device tries to copy a game — not when it merely looks at your list."),
      items: grants.isEmpty ? [SettingsRow.caption("no-paired", L("No paired devices yet."))] : grantRows)
    let excludedRows: [MenuItem] = excluded.map { e in
      SettingsRow.action("excluded-\(e.gameID)", e.title, L("Share this game again."), icon: "arrow.uturn.backward", badge: L("Share Again")) {
        shareAgain(e.gameID)
      }
    }
    let notShared = MenuSection(
      id: "excluded", header: L("Games Not Shared"),
      footer: L("Excluded games never appear in what this device serves, even to a device that already knows about them."),
      items: excluded.isEmpty ? [SettingsRow.caption("all-shared", L("Every game in your library is shared."))] : excludedRows)
    return MenuModel(sections: [share, paired, notShared])
  }

  static func grant(peerName: String, current: ContinuityLibraryGrant, hasExplicitGrant: Bool,
                    choose: @escaping (ContinuityLibraryGrant) -> Void, clear: @escaping () -> Void) -> MenuModel {
    let options = ContinuityLibraryGrant.allCases.map { (ContinuityGrantDetailView.title(for: $0), $0) }
    var sections = [MenuSection(id: "grant", header: L("When This Device Asks"), footer: ContinuityManager.transportSecurityNotice, items: [
      SettingsRow.picker("grant", peerName, options, current,
                         L("Always Allow copies without asking. Ask Every Time asks per game. Don't Share hides your list."),
                         set: choose),
    ])]
    if hasExplicitGrant {
      sections.append(MenuSection(id: "clear", footer: L("Clearing the setting puts this device back to asking you every time."), items: [
        SettingsRow.action("clear", L("Clear This Setting"), L("Back to asking every time."), icon: "arrow.counterclockwise", run: clear),
      ]))
    }
    return MenuModel(sections: sections)
  }
}
