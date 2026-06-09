// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    EmulationCoordinator.shared().isExternalDisplayConnected = true

    if AppConsts.useSwiftUI {
      guard let windowScene = scene as? UIWindowScene else { return }
      let window = UIWindow(windowScene: windowScene)

#if os(tvOS)
      // tvOS has no wired external-display emulation path; show an empty placeholder.
      window.rootViewController = UIHostingController(rootView: Color.black)
#else
      // iOS / Mac Catalyst: instantiate the real external-display emulation VC from its storyboard.
      // The SwiftUI app-shell graft sets the scene config's storyboard to nil (AppDelegate), so the
      // storyboard no longer auto-loads — we load it explicitly here. Loading it wires the
      // rendererView/waitView IBOutlets and runs viewDidLoad, which calls
      // registerExternalDisplayView:, re-parenting the shared Metal render host onto the external
      // screen. Without this the external window stayed a black placeholder. Falls back to black if
      // the storyboard can't be loaded so a connect never crashes.
      let storyboard = UIStoryboard(name: "ExternalDisplay", bundle: nil)
      if let externalVC = storyboard.instantiateInitialViewController() {
        window.rootViewController = externalVC
      } else {
        window.rootViewController = UIHostingController(rootView: Color.black)
      }
#endif

      if let tint = UIColor(named: "DolphinTint") {
        window.tintColor = tint
      }
      self.window = window
      window.makeKeyAndVisible()

#if !os(tvOS)
      // UIKit may ignore overscanCompensation if set before the external window is on-screen.
      DispatchQueue.main.async {
        TVEmulationBridge.setOverscanFullscreenEnabled(TVEmulationBridge.overscanFullscreenEnabled())
      }
#endif
    }
  }

  func sceneDidDisconnect(_ scene: UIScene) {
    EmulationCoordinator.shared().isExternalDisplayConnected = false
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    //
  }

  func sceneWillResignActive(_ scene: UIScene) {
    //
  }

  func sceneWillEnterForeground(_ scene: UIScene) {
    //
  }

  func sceneDidEnterBackground(_ scene: UIScene) {
    //
  }
}
