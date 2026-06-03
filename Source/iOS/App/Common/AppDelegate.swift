// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    // TODO(sentry): Sentry SPM dependency + dSYM upload are wired in Project.swift, but the SDK is
    // NOT started — no DSN was found anywhere in the repo (the installer left only the auth token in
    // .sentryclirc, which is for dSYM upload, not the runtime DSN). To enable runtime crash/error
    // reporting, retrieve the DSN (Sentry org `provenance-emu`, project `icube`) and uncomment:
    //
    //   import Sentry  // add at top of file
    //   SentrySDK.start { options in
    //     options.dsn = "https://<public-key>@<org-id>.ingest.sentry.io/<project-id>"
    //     options.debug = false
    //   }
    //
    // Open decision before enabling: Firebase init (FirebaseService.mm) is gated
    // `#if !TARGET_OS_TV && !TARGET_OS_MACCATALYST` — decide whether Sentry should mirror that gating.
    // NOTE: iCube already ships Firebase Crashlytics; running two crash SDKs is a deliberate choice
    // (and has privacy-policy implications).
    ServiceManager.shared.application(application, didFinishLaunchingWithOptions: launchOptions)
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
