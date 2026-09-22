// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit
import PVHelp

/// Presents an in-app wiki page over whatever is currently on screen, for callers that can't
/// easily host a SwiftUI `NavigationStack` themselves — in particular Objective-C++ alert code
/// (`MsgAlertManager.mm`). Exposed to Objective-C via the generated `iCube-Swift.h` header
/// (see the `#import "iCube-Swift.h"` pattern already used by `EmulationCoordinator.mm` /
/// `DolphinCoreService.mm` / `DOLConfigBridge.mm`).
///
/// Unlike opening the page in Safari, this works on tvOS (no browser) and offline (the page
/// content is bundled — see `WikiContentProvider`), which is the whole point of routing the
/// missing-BIOS "Learn More" action through here instead of `UIApplication.open`.
@objc(DOLHelpBridge)
final class HelpPresentationBridge: NSObject {
  /// Presents the GameCube BIOS (IPL) guide. Safe to call from any thread.
  @objc static func presentBIOSGuide() {
    presentWikiPage(path: WikiConstants.Paths.biosRequirements, title: L("BIOS Requirements"))
  }

  @objc static func presentWikiPage(path: String, title: String) {
    DispatchQueue.main.async {
      guard let presenter = topViewController() else { return }
      let host = UIHostingController(rootView: NavigationStack {
        WikiPageView(path: path, title: title)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button(L("Close")) {
                presenter.dismiss(animated: true)
              }
            }
          }
      })
#if os(iOS)
      host.modalPresentationStyle = .pageSheet
#endif
      presenter.present(host, animated: true)
    }
  }

  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    guard let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first,
          var top = window.rootViewController else {
      return nil
    }
    while let presented = top.presentedViewController {
      top = presented
    }
    return top
  }
}
