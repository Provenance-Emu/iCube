// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import PVWebServer
#if os(iOS)
import UIKit
#endif

/// Library import sheet: live Web UI / WebDAV URLs with copy helpers (iFly-style Wi-Fi upload guide).
struct LibraryWebImportView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @State private var webURL: String = ""
  @State private var webDavURL: String = ""
  @State private var ipAddress: String = ""

  var body: some View {
    NavigationStack {
      List {
        Section {
          urlRow(title: L("Web UI"), url: webURL)
          urlRow(title: L("WebDAV"), url: webDavURL)
          if !ipAddress.isEmpty {
            HStack {
              Text(L("Device IP"))
              Spacer()
              Text(ipAddress)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
          }
        } footer: {
          Text(L("Drop GameCube and Wii files onto iCube from a computer or phone on the same Wi-Fi: open the Web UI address in a browser, or connect to the WebDAV address from a file manager."))
        }

#if os(iOS)
        Section {
          Button(L("Learn More About Web Import")) {
            if let url = URL(string: "https://icube-emu.com/help/web-import") {
              openURL(url)
            }
          }
        }
#endif
      }
      .navigationTitle(L("Upload via Wi-Fi"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L("Done")) { dismiss() }
        }
      }
      .onAppear { refreshURLs() }
      .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
        refreshURLs()
      }
    }
  }

  @ViewBuilder
  private func urlRow(title: String, url: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)
      if url.isEmpty {
        Text(L("Not Running"))
          .foregroundStyle(.secondary)
      } else {
        Text(url)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .lineLimit(3)
        HStack(spacing: 12) {
          Button {
            copyToPasteboard(url)
          } label: {
            Label(L("Copy"), systemImage: "doc.on.doc")
          }
          .buttonStyle(.bordered)
#if os(iOS)
          if let link = URL(string: url) {
            Button {
              openURL(link)
            } label: {
              Label(L("Open"), systemImage: "safari")
            }
            .buttonStyle(.bordered)
          }
#endif
        }
      }
    }
    .padding(.vertical, 4)
  }

  private func refreshURLs() {
    webURL = PVWebServer.shared.urlString ?? ""
    webDavURL = PVWebServer.shared.webDavURLString ?? ""
    ipAddress = PVWebServer.shared.ipAddress ?? ""
  }

  private func copyToPasteboard(_ value: String) {
#if os(iOS)
    UIPasteboard.general.string = value
    NotificationCenter.default.post(
      name: NSNotification.Name("DOLShowSnackbar"),
      object: nil,
      userInfo: ["text": L("Copied to clipboard")]
    )
#endif
  }
}
