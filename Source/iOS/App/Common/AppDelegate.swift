// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    // Start Sentry as early as possible so it captures crashes during app launch. Configuration
    // lives in SentryTelemetryService (emulation-gated tracing + hang tracking).
    SentryTelemetryService.configure()

    // Settings-sync backbone: one global Config-changed hook (debounced auto-save of menu changes so
    // settings persist between runs, + a coalesced refresh notification so open settings UI re-reads
    // live Config after resets/external changes).
    DOLConfigBridge.startConfigAutoSyncBridge()

    return ServiceManager.shared.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func applicationWillTerminate(_ application: UIApplication) {
    ServiceManager.shared.applicationWillTerminate()
  }

  func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
    ServiceManager.shared.applicationDidReceiveMemoryWarning()
  }

  func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    ServiceManager.shared.open(url: url, options: options)
  }

  func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    // For tvOS, override any storyboard-based scene configuration and provide a programmatic scene.
    // This prevents crashes due to missing storyboards and enables a SwiftUI-based root.
    if AppConsts.useSwiftUI {
      let role = connectingSceneSession.role
      let config = UISceneConfiguration(name: "Default Configuration", sessionRole: role)
      if role == .windowExternalDisplayNonInteractive {
        config.delegateClass = ExternalDisplaySceneDelegate.self
      } else {
        config.delegateClass = MainDisplaySceneDelegate.self
      }
      config.storyboard = nil
      return config
    } else {
      return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
  }

  func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
    //
  }
}
