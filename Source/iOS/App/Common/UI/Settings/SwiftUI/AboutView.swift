// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreHaptics
import Foundation
import PVHelp
import PVWebServer
import QuartzCore
import SwiftUI
import UIKit
#if os(iOS)
import AudioToolbox
import SafariServices
#endif
#if canImport(GameController)
import GameController
#endif
#if os(iOS)
#endif

struct AboutView: View {
  @Environment(\.openURL) private var openURL
  @State private var membershipStatus = ""
  @State private var showPlus = false
  #if os(tvOS)
  @Environment(\.dismiss) private var dismiss
  @Environment(\.settingsPaneBack) private var paneBack
  @Environment(\.icubeLeafParentTitle) private var parentTitle
  @State private var confirmReset = false
  #endif

  private func openPlus() {
    #if APPSTORE
    showPlus = true
    #endif
  }

  var body: some View {
    Group {
      #if os(tvOS)
      MenuScreen(model: AboutModelBuilder.make(
        appVersion: VersionManager.shared().appVersion.userFacing, coreVersion: VersionManager.shared().coreVersion,
        open: { openURL($0) }, blog: AnyView(DolphinBlogView()), help: AnyView(WikiHelpView()),
        resetAll: { confirmReset = true }, membershipStatus: membershipStatus, openPlus: openPlus),
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

          VStack(spacing: 8) {
            Text(L("Shared Plus Membership")).icubeText(.section)
            #if APPSTORE
            Button(action: openPlus) { Text(L(membershipStatus)).icubeText(.body) }
            #else
            Text(L(membershipStatus)).icubeText(.body)
            #endif
            Text(L(SharedPlusEntitlement.restoreGuidance)).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary))
          }
          .multilineTextAlignment(.center)

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
    .sheet(isPresented: $showPlus) { PlusPurchaseView() }
    .onAppear { membershipStatus = SharedPlusEntitlement.shared.statusText }
    .onReceive(NotificationCenter.default.publisher(for: .sharedPlusEntitlementDidChange)) { _ in
      membershipStatus = SharedPlusEntitlement.shared.statusText
    }
  }
}

private struct PlusPurchaseView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var entitlement = SharedPlusEntitlement.shared
  @State private var loaded = false
  @State private var status = ""

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        Text("iCube Plus Lifetime").icubeText(.section)
        Text(status)
        Text("A one-time purchase. Provenance can recognize your Plus purchase on this device when both apps support sharing.")
        Text("Manual library sharing and patches remain free.").foregroundStyle(.secondary)
        if !entitlement.hasPurchased {
          if let product = entitlement.product {
            Button("Buy Lifetime · \(product.displayPrice)") {
              Task { await entitlement.purchase() }
            }.disabled(entitlement.busy)
          } else if loaded {
            Text("Lifetime is currently unavailable.")
            Button("Retry") { Task { await entitlement.loadProduct() } }
          } else {
            ProgressView()
          }
        }
        Button("Restore Purchases") {
          Task { await entitlement.restore() }
        }.disabled(entitlement.busy)
        if let message = entitlement.message {
          Text(message).foregroundStyle(.secondary)
        }
        Button("Done") { dismiss() }
      }
      .multilineTextAlignment(.center)
      .padding(32)
    }
    .task {
      status = entitlement.statusText
      await entitlement.loadProduct()
      loaded = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .sharedPlusEntitlementDidChange)) { _ in
      status = entitlement.statusText
    }
  }
}
