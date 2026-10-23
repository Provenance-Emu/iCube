// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit
import CoreHaptics
import QuartzCore
import PVWebServer
import PVHelp
#if os(iOS)
import SafariServices
import AudioToolbox
#endif
#if canImport(GameController)
import GameController
#endif
#if os(iOS)
#endif
import Foundation

struct AboutView: View {
  @Environment(\.openURL) private var openURL
  #if os(tvOS)
  @Environment(\.dismiss) private var dismiss
  @Environment(\.settingsPaneBack) private var paneBack
  @Environment(\.icubeLeafParentTitle) private var parentTitle
  @State private var confirmReset = false
  #endif

  var body: some View {
    #if os(tvOS)
    MenuScreen(model: AboutModelBuilder.make(
      appVersion: VersionManager.shared().appVersion.userFacing, coreVersion: VersionManager.shared().coreVersion,
      open: { openURL($0) }, blog: AnyView(DolphinBlogView()), help: AnyView(WikiHelpView()),
      resetAll: { confirmReset = true }),
      style: .list, onBack: SettingsLeafScreen.backAction(paneBack: paneBack, dismiss: { dismiss() }),
      tvHeader: SettingsLeafScreen.header(title: L("About"), parentTitle: parentTitle), tvInset: .xxl)
      .alert(L("Reset All Settings"), isPresented: $confirmReset) {
        Button(L("Cancel"), role: .cancel) {}
        Button(L("Reset"), role: .destructive) { DOLConfigBridge.resetAllToDefaults() }
      } message: { Text(L("This will reset all settings to factory defaults. This may require restarting emulation.")) }
    #else
    ScrollView {
      VStack(spacing: 20) {
        // Top spacer to mimic storyboard padding
        Color.clear.frame(height: 0)
        ICubeAnimatedLogo()

        Text("iCube")
          .font(.system(size: 28, weight: .semibold))
          .foregroundColor(.blue)

        // App version / build + Dolphin core version.
        VStack(spacing: 2) {
          Text(verbatim: "\(L("Version")) \(VersionManager.shared().appVersion.userFacing)")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Text(verbatim: "\(L("Core")) \(VersionManager.shared().coreVersion)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Text("© 2003-2015+ Dolphin Team.\n© 2025+ iCube Project.")
          .multilineTextAlignment(.center)

        Text("SwiftUI version by Joe Mattiello")
          .multilineTextAlignment(.center)

        Button("github.com/JoeMatt") {
          if let url = URL(string: "https://github.com/JoeMatt") {
            openURL(url)
          }
        }

        Button("joemattiello.dev") {
          if let url = URL(string: "https://joemattiello.dev") {
            openURL(url)
          }
        }

        Text("iCube is an unofficial and separately maintained port of Dolphin to iOS. The iCube Project has no relation to Dolphin Team.")
          .multilineTextAlignment(.center)

        // Fork lineage with tappable source links.
        VStack(spacing: 8) {
          Text(L("iCube is a fork of OatmealDome's DolphiniOS, based on the Dolphin emulator."))
            .multilineTextAlignment(.center)
            .font(.subheadline)
            .foregroundStyle(.secondary)
          VStack(spacing: 6) {
            Button("dolphinios.oatmealdome.me") {
              if let url = URL(string: "https://dolphinios.oatmealdome.me") { openURL(url) }
            }
            Button("dolphin-emu.org") {
              if let url = URL(string: "https://dolphin-emu.org") { openURL(url) }
            }
            Button("icube-emu.com") {
              if let url = URL(string: "https://icube-emu.com") { openURL(url) }
            }
          }
          .font(.callout)
        }
        .padding(.vertical, 4)

        Text("\"GameCube\" and \"Wii\" are trademarks of Nintendo. iCube is not affiliated with Nintendo in any way.")
          .multilineTextAlignment(.center)

        Text("This software should not be used to play games you do not legally own.")
          .multilineTextAlignment(.center)

        Button(L("Source Code")) {
          if let url = URL(string: "https://github.com/provenance-Emu/icube") {
            openURL(url)
          }
        }

        NavigationLink(destination: DolphinBlogView().padBackNavigation()) { Label(L("Dolphin Blog"), systemImage: "newspaper") }
        NavigationLink(destination: WikiHelpView().padBackNavigation()) { Label(L("Help"), systemImage: "questionmark.circle") }
        SettingsResetAllButton(role: .destructive) { Label(L("Reset All Settings"), systemImage: "arrow.counterclockwise") }

        Color.clear.frame(height: 0)
      }
      .padding(.horizontal, 20)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle(L("About iCube"))
    #endif
  }
}
