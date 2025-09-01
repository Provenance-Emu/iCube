// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit
import SwiftUI
import CoreSpotlight

class MainDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
#if !os(tvOS)
  private var pendingShortcutItem: UIApplicationShortcutItem?
#endif

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    MainSceneCoordinator.shared().mainScene = scene as? UIWindowScene

    // On tvOS, we do not use storyboards. Create the window and root UI programmatically using SwiftUI.
    if AppConsts.useSwiftUI {
      guard let windowScene = scene as? UIWindowScene else { return }
      let window = UIWindow(windowScene: windowScene)
      let rootView = TVRootView()
      window.rootViewController = UIHostingController(rootView: rootView)
      self.window = window
      window.makeKeyAndVisible()
#if !os(tvOS)
      // Handle cold-boot quick actions after UI is ready
      if let shortcut = connectionOptions.shortcutItem {
        pendingShortcutItem = shortcut
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
          guard let self = self, let item = self.pendingShortcutItem else { return }
          self.handleShortcut(item) { _ in
            self.pendingShortcutItem = nil
          }
        }
      }
#endif
    }
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

  func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    #if !os(tvOS)
    if userActivity.activityType == CSSearchableItemActionType,
       let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
       identifier.hasPrefix("dios.game.") {
      let gameID = String(identifier.dropFirst("dios.game.".count))
      NotificationCenter.default.post(name: NSNotification.Name("DOLLaunchGameByGameID"), object: nil, userInfo: ["gameID": gameID])
    }
    #endif
  }

#if !os(tvOS)
  func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
    // Defer slightly to ensure UI has mounted
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      self.handleShortcut(shortcutItem, completion: completionHandler)
    }
  }

  private func handleShortcut(_ shortcutItem: UIApplicationShortcutItem, completion: @escaping (Bool) -> Void) {
    switch shortcutItem.type {
    case "dios.quick.continue":
      // Retry a few times in case library hasn't hydrated yet
      attemptContinue(attempt: 0)
      completion(true)
    case "dios.quick.import":
      NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Import Game…")])
      NotificationCenter.default.post(name: NSNotification.Name("DOLShowImportGame"), object: nil)
      completion(true)
    case "dios.quick.settings":
      NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Opening Settings…")])
      NotificationCenter.default.post(name: NSNotification.Name("DOLShowSettings"), object: nil)
      completion(true)
    default:
      completion(false)
    }
  }
#endif

  private func attemptContinue(attempt: Int) {
    let games = TVLibraryBridge.currentGames()
    if let last = games.first {
      NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Continuing %@"), last.title)])
      NotificationCenter.default.post(name: NSNotification.Name("DOLLaunchGameByGameID"), object: nil, userInfo: ["gameID": last.gameID])
      return
    }
    if attempt < 8 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.attemptContinue(attempt: attempt + 1) }
    }
  }
}
