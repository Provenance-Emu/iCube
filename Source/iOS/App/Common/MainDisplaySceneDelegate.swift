// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit
import SwiftUI

class MainDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    MainSceneCoordinator.shared().mainScene = scene as? UIWindowScene

    // On tvOS, we do not use storyboards. Create the window and root UI programmatically using SwiftUI.
    #if os(tvOS)
    guard let windowScene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: windowScene)
    let rootView = TVRootView()
    window.rootViewController = UIHostingController(rootView: rootView)
    self.window = window
    window.makeKeyAndVisible()
    #endif
  }

  func sceneDidDisconnect(_ scene: UIScene) {
    MainSceneCoordinator.shared().mainScene = nil
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    ServiceManager.shared.applicationDidBecomeActive()

    BootNoticeManager.shared().presentToSceneIfNecessary()
  }

  func sceneWillResignActive(_ scene: UIScene) {
    ServiceManager.shared.applicationWillResignActive()
  }

  func sceneWillEnterForeground(_ scene: UIScene) {
    //
  }

  func sceneDidEnterBackground(_ scene: UIScene) {
    ServiceManager.shared.applicationDidEnterBackground()
  }
}
