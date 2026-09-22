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
          urlRow(title: L("Finder / WebDAV"), url: webDavURL)
          if !ipAddress.isEmpty {
            HStack {
              Text(L("Device IP"))
              Spacer()
              Text(ipAddress)
                .foregroundStyle(.secondary)
              #if !os(tvOS)
                .textSelection(.enabled)
              #endif
            }
          }
        } footer: {
          Text(L("Drop GameCube and Wii files onto iCube from a computer or phone on the same Wi-Fi. Open the address in a browser, or in Finder choose Go › Connect to Server and enter the same address as Guest."))
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
      #if !os(tvOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L("Done")) { dismiss() }
        }
      }
      .onAppear {
        // This sheet exists to show the upload address, so opening it is an
        // explicit request for the server: start it on demand rather than
        // reporting "Not Running" at the one moment the user is asking for it.
        NotificationCenter.default.post(
          name: Notification.Name(PVWebServerUserAccessRequestedNotificationName), object: nil)
        refreshURLs()
      }
      .onDisappear {
        NotificationCenter.default.post(
          name: Notification.Name(PVWebServerUserAccessReleasedNotificationName), object: nil)
      }
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
        #if !os(tvOS)
          .textSelection(.enabled)
        #endif
          .lineLimit(3)
#if os(iOS)
        // tvOS has no pasteboard and no browser to open the URL in, so it reads the
        // address off the screen instead — no action row there.
        HStack(spacing: 12) {
          Button {
            copyToPasteboard(url)
          } label: {
            Label(L("Copy"), systemImage: "doc.on.doc")
          }
          .buttonStyle(.bordered)
          if let link = URL(string: url) {
            Button {
              openURL(link)
            } label: {
              Label(L("Open"), systemImage: "safari")
            }
            .buttonStyle(.bordered)
          }
        }
#endif
      }
    }
    .padding(.vertical, 4)
  }

  private func refreshURLs() {
    webURL = PVWebServer.shared.urlString ?? ""
    webDavURL = PVWebServer.shared.webDavURLString ?? ""
    ipAddress = PVWebServer.shared.ipAddress ?? ""
  }

#if os(iOS)
  private func copyToPasteboard(_ value: String) {
    UIPasteboard.general.string = value
    NotificationCenter.default.post(
      name: NSNotification.Name("DOLShowSnackbar"),
      object: nil,
      userInfo: ["text": L("Copied to clipboard")]
    )
  }
#endif
}
