// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Pure: the sending side of a handoff (`ContinuityHandoffSheet`) as rows on the menu
/// engine, for tvOS. iOS keeps its `List`; this exists because the stock phone list on
/// Apple TV left the notice and status as unfocusable footnote text and the three buttons
/// as the only thing the remote could reach.
enum ContinuityHandoffModelBuilder {
  static let offerItemID = "offer"
  static let stopItemID = "stop"
  static let doneItemID = "done"

  static func make(gameTitle: String, gameID: String, isOffering: Bool, error: String?,
                   begin: @escaping () -> Void, stop: @escaping () -> Void, done: @escaping () -> Void) -> MenuModel {
    var sections: [MenuSection] = []
    // A row, not a footer: "your saves cross the network unencrypted" is easy to miss as a
    // footnote on a TV (see `ContinuitySecurityNotice`).
    sections.append(MenuSection(id: "notice", items: [
      SettingsRow.caption("notice", ContinuityManager.transportSecurityNotice),
    ]))
    sections.append(MenuSection(id: "game", header: L("Game"), items: [
      SettingsRow.caption("game-title", gameTitle),
      SettingsRow.caption("game-id", gameID),
    ]))
    if let error, !error.isEmpty {
      sections.append(MenuSection(id: "error", items: [SettingsRow.caption("error", error)]))
    }
    if isOffering {
      sections.append(MenuSection(id: "handoff", header: L("Hand Off"), items: [
        SettingsRow.caption("status", L("Visible to nearby devices. Open iCube on the other device and pick this one.")),
        SettingsRow.destructive(stopItemID, L("Stop Offering"), L("Hide this game from nearby devices."), icon: "xmark.circle", run: stop),
      ]))
    } else {
      sections.append(MenuSection(id: "handoff", header: L("Hand Off"), items: [
        SettingsRow.action(offerItemID, L("Offer To Nearby Devices"), L("Let another iCube on this network pick up this game where you are."),
                           icon: "antenna.radiowaves.left.and.right", run: begin),
      ]))
    }
    sections.append(MenuSection(id: "done", items: [
      SettingsRow.action(doneItemID, L("Done"), L("Close this screen."), icon: "checkmark", run: done),
    ]))
    return MenuModel(sections: sections)
  }
}
