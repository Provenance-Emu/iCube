// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Settings → Connected Apps, on the menu engine. Install state comes from
/// `EcosystemBridge.peerInstalled` (URL-scheme probes, iOS only: the leaf is
/// not listed on tvOS, which cannot open another app's scheme).
struct ConnectedAppsSettingsView: View {
  @Environment(\.openURL) private var openURL
  @State private var provenanceInstalled = false
  @State private var iflyInstalled = false

  /// App Store pages, for a sibling that is not installed.
  static let provenanceStoreURL = URL(string: "https://apps.apple.com/app/id1596862805")!
  static let iflyStoreURL = URL(string: "https://apps.apple.com/app/id6753563089")!

  var body: some View {
    SettingsLeafScreen(model: ConnectedAppsModelBuilder.make(apps: [
      .init(id: "provenance", name: "Provenance", icon: "square.grid.3x3.fill", installed: provenanceInstalled) {
        open(scheme: EcosystemSchemes.provenanceScheme, installed: provenanceInstalled, store: Self.provenanceStoreURL)
      },
      .init(id: "ifly", name: "iFly", icon: "circle.circle", installed: iflyInstalled) {
        open(scheme: EcosystemSchemes.iflyScheme, installed: iflyInstalled, store: Self.iflyStoreURL)
      },
    ]), title: L("Connected Apps"), sync: sync)
  }

  private func sync() {
    provenanceInstalled = EcosystemBridge.peerInstalled(scheme: EcosystemSchemes.provenanceScheme)
    iflyInstalled = EcosystemBridge.peerInstalled(scheme: EcosystemSchemes.iflyScheme)
  }

  private func open(scheme: String, installed: Bool, store: URL) {
    if installed, let url = URL(string: "\(scheme)://") {
      openURL(url)
    } else {
      openURL(store)
    }
  }
}
