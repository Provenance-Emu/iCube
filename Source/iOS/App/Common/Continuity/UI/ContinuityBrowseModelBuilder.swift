// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct ContinuityPeerSummary: Equatable {
  let id: String
  let name: String
  let subtitle: String
  let glyph: String
}

/// Pure: the Nearby leaf (`ContinuityBrowseView`) as rows.
enum ContinuityBrowseModelBuilder {
  static func make(peers: [ContinuityPeerSummary], trusted: [(id: String, name: String)], sharesLibrary: Bool, showsDone: Bool,
                   peerDetail: @escaping (String) -> AnyView, trustedDetail: @escaping (String) -> AnyView,
                   sharing: AnyView, done: @escaping () -> Void) -> MenuModel {
    var sections: [MenuSection] = []
    let peerRows: [MenuItem] = peers.isEmpty
      ? [SettingsRow.caption("looking", L("Looking for other devices running iCube on this network…"))]
      : peers.map { p in
          var item = SettingsRow.destination("peer-\(p.id)", p.name, L("Continue this device's game here, or browse its games."), icon: p.glyph, view: peerDetail(p.id))
          item.subtitle = p.subtitle
          return item
        }
    sections.append(MenuSection(id: "peers", header: L("Nearby Devices"), footer: ContinuityManager.transportSecurityNotice, items: peerRows))
    var shareRow = SettingsRow.destination("share-library", L("Share My Library"), L("Let paired devices browse and copy this device's games."),
                                           icon: "square.stack.3d.up", view: sharing)
    shareRow.badge = sharesLibrary ? L("On") : L("Off")
    sections.append(MenuSection(id: "this-device", header: L("This Device"), items: [shareRow]))
    if !trusted.isEmpty {
      sections.append(MenuSection(id: "paired", header: L("Paired Devices"), items: trusted.map {
        SettingsRow.destination("trusted-\($0.id)", $0.name, L("When this device was paired, and forget it."), icon: "checkmark.shield", view: trustedDetail($0.id))
      }))
    }
    if showsDone {
      sections.append(MenuSection(id: "done", items: [SettingsRow.action("done", L("Done"), L("Close this screen."), icon: "checkmark", run: done)]))
    }
    return MenuModel(sections: sections)
  }
}
