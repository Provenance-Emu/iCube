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

#if os(iOS)
/// Wrapper for presenting SFSafariViewController in SwiftUI
struct SafariView: UIViewControllerRepresentable {
  let url: URL
  func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
  func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) { }
}

extension View {
  /// iOS long-press context menu for a LAN server URL: Copy (UIPasteboard) and Open (system browser
  /// via the SwiftUI openURL action). tvOS has no long-press and no usable openURL/browser, so this
  /// is iOS-only and the tvOS call sites simply render the URL as plain text.
  @ViewBuilder
  func networkURLContextMenu(_ urlString: String, openURL: OpenURLAction) -> some View {
    self.contextMenu {
      Button {
        UIPasteboard.general.string = urlString
      } label: {
        Label(L("Copy"), systemImage: "doc.on.doc")
      }
      if let u = URL(string: urlString) {
        Button {
          openURL(u)
        } label: {
          Label(L("Open"), systemImage: "safari")
        }
      }
    }
  }
}
#endif
