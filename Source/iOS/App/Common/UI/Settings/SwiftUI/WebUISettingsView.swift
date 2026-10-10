// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import PVWebServer
import SwiftUI

/// The upload server's addresses: Web UI and Finder / WebDAV. Read-only; the server is started by
/// `WebServerLifecycleService`, not from here.
struct WebUISettingsView: View {
  @Environment(\.openURL) private var openURL
  @State private var webURLDisplay = ""
  @State private var webDavDisplay = ""
  #if os(iOS)
  @State private var showSafari = false
  @State private var safariURL: URL?
  #endif

  /// `startServers()` binds asynchronously, so the URL can still be nil when Settings appears.
  private enum Polling {
    static let attempts = 20
    static let intervalNanoseconds: UInt64 = 100_000_000
  }

  private static let helpURLString = "https://icube-emu.com/help/web-import"

  var body: some View {
    List {
      Section(footer: webImportFooter) {
        HStack {
          Text(L("Web UI"))
          Spacer()
          webUIValue
        }
        HStack {
          Text(L("Finder / WebDAV"))
          Spacer()
          webDavValue
        }
      }
    }
    .navigationTitle(L("Web UI & WebDAV"))
    .task { await refresh() }
    #if os(iOS)
    .sheet(isPresented: $showSafari) {
      if let url = safariURL { SafariView(url: url) }
    }
    #endif
  }

  @ViewBuilder
  private var webUIValue: some View {
    #if os(iOS)
    if webURLDisplay.isEmpty {
      Text(L("Not Running")).foregroundStyle(.secondary)
    } else {
      Button {
        guard let url = URL(string: webURLDisplay) else { return }
        safariURL = url
        showSafari = true
      } label: {
        Text(webURLDisplay)
          .foregroundStyle(.blue)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .buttonStyle(.plain)
      .networkURLContextMenu(webURLDisplay, openURL: openURL)
    }
    #else
    urlText(webURLDisplay)
    #endif
  }

  @ViewBuilder
  private var webDavValue: some View {
    #if os(iOS)
    if webDavDisplay.isEmpty {
      Text(L("Not Running")).foregroundStyle(.secondary)
    } else {
      urlText(webDavDisplay).networkURLContextMenu(webDavDisplay, openURL: openURL)
    }
    #else
    urlText(webDavDisplay)
    #endif
  }

  private func urlText(_ value: String) -> some View {
    Text(value.isEmpty ? L("Not Running") : value)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.middle)
  }

  /// Explains web importing and links to the help page. On iOS "Learn more" is a tappable link; tvOS has no
  /// browser or openURL, so the address is plain text there.
  @ViewBuilder
  private var webImportFooter: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(L("Drop GameCube and Wii files onto iCube from a computer or phone on the same Wi-Fi. Open the address in a browser, or in Finder choose Go › Connect to Server and enter the same address as Guest."))
      #if os(iOS)
      Button(L("Learn more")) {
        if let url = URL(string: Self.helpURLString) { openURL(url) }
      }
      .font(.footnote)
      #else
      Text(verbatim: Self.helpURLString)
        .font(.footnote)
        .foregroundStyle(.secondary)
      #endif
    }
  }

  @MainActor
  private func refresh() async {
    webURLDisplay = PVWebServer.shared.urlString ?? ""
    webDavDisplay = PVWebServer.shared.webDavURLString ?? ""
    #if os(iOS)
    for _ in 0..<Polling.attempts {
      if let url = PVWebServer.shared.urlString, !url.isEmpty {
        webURLDisplay = url
        webDavDisplay = PVWebServer.shared.webDavURLString ?? ""
        break
      }
      try? await Task.sleep(nanoseconds: Polling.intervalNanoseconds)
    }
    #endif
  }
}
