// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

enum AboutLinks {
  static let github = URL(string: "https://github.com/JoeMatt")!
  static let site = URL(string: "https://joemattiello.dev")!
  static let dolphinios = URL(string: "https://dolphinios.oatmealdome.me")!
  static let dolphin = URL(string: "https://dolphin-emu.org")!
  static let icube = URL(string: "https://icube-emu.com")!
  static let source = URL(string: "https://github.com/Provenance-Emu/iCube")!
}

/// Pure: the About leaf as rows. Captions carry the legal text the hand-built screen showed.
enum AboutModelBuilder {
  static func make(appVersion: String, coreVersion: String, open: @escaping (URL) -> Void,
                   blog: AnyView, help: AnyView, resetAll: @escaping () -> Void) -> MenuModel {
    let version = MenuSection(id: "version", header: L("Version"),
                              footer: L("iCube is an unofficial and separately maintained port of Dolphin to iOS. The iCube Project has no relation to Dolphin Team."),
                              items: [
      SettingsRow.action("version", L("Version"), L("The app version and build number."), icon: "app.badge", badge: appVersion) {},
      SettingsRow.action("core", L("Core"), L("The Dolphin core this build embeds."), icon: "cpu", badge: coreVersion) {},
    ])
    let icube = MenuSection(id: "icube", header: L("iCube"), footer: L("SwiftUI version by Joe Mattiello"), items: [
      SettingsRow.action("icube-site", "icube-emu.com", L("The iCube website."), icon: "globe") { open(AboutLinks.icube) },
      SettingsRow.action("source", L("Source Code"), L("iCube on GitHub."), icon: "chevron.left.forwardslash.chevron.right") { open(AboutLinks.source) },
      SettingsRow.action("author-github", "github.com/JoeMatt", L("The author on GitHub."), icon: "person") { open(AboutLinks.github) },
      SettingsRow.action("author-site", "joemattiello.dev", L("The author's site."), icon: "person.text.rectangle") { open(AboutLinks.site) },
    ])
    let dolphin = MenuSection(id: "dolphin", header: L("Dolphin"),
                              footer: L("iCube is a fork of OatmealDome's DolphiniOS, based on the Dolphin emulator."), items: [
      SettingsRow.action("dolphinios", "dolphinios.oatmealdome.me", L("DolphiniOS, which iCube forked."), icon: "globe") { open(AboutLinks.dolphinios) },
      SettingsRow.action("dolphin", "dolphin-emu.org", L("The Dolphin emulator."), icon: "globe") { open(AboutLinks.dolphin) },
    ])
    let helpSection = MenuSection(id: "help", header: L("Help"), items: [
      SettingsRow.destination("blog", L("Dolphin Blog"), L("Progress reports from the Dolphin team."), icon: "newspaper", view: blog),
      SettingsRow.destination("help", L("Help"), L("The iCube wiki."), icon: "questionmark.circle", view: help),
    ])
    let maintenance = MenuSection(id: "maintenance",
                                  footer: L("\"GameCube\" and \"Wii\" are trademarks of Nintendo. iCube is not affiliated with Nintendo in any way. This software should not be used to play games you do not legally own."),
                                  items: [
      SettingsRow.destructive("reset-all", L("Reset All Settings"), L("Resets every setting to its default. May require restarting emulation."),
                              icon: "arrow.counterclockwise", run: resetAll),
    ])
    return MenuModel(sections: [version, icube, dolphin, helpSection, maintenance])
  }
}
