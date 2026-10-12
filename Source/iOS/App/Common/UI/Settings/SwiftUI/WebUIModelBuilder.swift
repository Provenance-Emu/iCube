// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Pure: the upload server's addresses as rows. The addresses are badges (tag role) so they read as
/// values, and the rows are focusable so the info shelf explains each one.
enum WebUIModelBuilder {
  static let helpURL = URL(string: "https://icube-emu.com/help/web-import")!

  static func make(webURL: String, webDavURL: String, open: @escaping (URL) -> Void) -> MenuModel {
    func shown(_ s: String) -> String { s.isEmpty ? L("Not Running") : s }
    let addresses = MenuSection(id: "addresses", header: L("Addresses"),
      footer: L("Drop GameCube and Wii files onto iCube from a computer or phone on the same Wi-Fi. Open the address in a browser, or in Finder choose Go › Connect to Server and enter the same address as Guest."),
      items: [
        SettingsRow.action("web-ui", L("Web UI"), L("Open this address in a browser on another device to upload games."), icon: "globe", badge: shown(webURL)) {},
        SettingsRow.action("webdav", L("Finder / WebDAV"), L("Connect to this address from Finder as Guest to drag files in."), icon: "externaldrive.connected.to.line.below", badge: shown(webDavURL)) {},
      ])
    let help = MenuSection(id: "help", items: [
      SettingsRow.action("learn-more", L("Learn more"), helpURL.absoluteString, icon: "questionmark.circle") { open(helpURL) },
    ])
    return MenuModel(sections: [addresses, help])
  }
}
