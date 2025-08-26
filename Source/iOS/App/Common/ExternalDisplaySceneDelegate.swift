// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit
import SwiftUI

class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    EmulationCoordinator.shared().isExternalDisplayConnected = true

    // On tvOS, create an empty window programmatically to avoid storyboard requirements.
    #if os(tvOS)
    guard let windowScene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: windowScene)
    // Placeholder content for external display on tvOS
    window.rootViewController = UIHostingController(rootView: Color.black)
    self.window = window
    window.makeKeyAndVisible()
    #endif
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
