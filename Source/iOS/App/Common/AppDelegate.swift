// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    // Before anything logs: a JIT debugger's undrained stdio pipe must not block main (ICUBE-AC).
    DebuggerStdio.makeStdioNonBlocking()
    #if os(iOS)
    // SkinKit's log hooks, before the first skin or catalog line.
    SkinKitSetup.configure()
    #endif
    MotionSettings.registerDefaults()
    DSUSettings.registerDefaults()

    // Start Sentry as early as possible so it captures crashes during app launch. Configuration
    // lives in SentryTelemetryService (emulation-gated tracing + hang tracking).
    SentryTelemetryService.configure()
    #if canImport(MetricKit) && !os(tvOS)
    // The app extensions can't receive MetricKit payloads; their signposts arrive here.
    ExtensionMetricsReporter.start()
    #endif

    // Settings-sync backbone: one global Config-changed hook (debounced auto-save of menu changes so
    // settings persist between runs, + a coalesced refresh notification so open settings UI re-reads
    // live Config after resets/external changes).
    DOLConfigBridge.startConfigAutoSyncBridge()

    // Single app-lifetime listener that resolves the resume/boot-into-state decision for
    // every emulation boot (see SaveStateService.resumeOrBootIntoPendingState()). Installed
    // once, here, instead of per-`EmulationScreen`-appearance so a navigation transition can
    // never leave two observers racing to consume the one-shot "Start Fresh" flag.
    SaveStateService.installDidStartObserver()
    PauseArbiter.shared.installObservers()
    SharedPlusEntitlement.shared.start()

    let started = ServiceManager.shared.application(application, didFinishLaunchingWithOptions: launchOptions)
    TemporaryServerGame.removeAbandoned()
    // Reconnects remote-library game downloads that ran while iCube was suspended or ended.
    BackgroundGameDownloader.shared.activate()
    RemoteGameDownloads.shared.start()
    #if os(iOS)
    // Seed local bundled skins after the user folder exists, without delaying launch or changing picks.
    Task { @MainActor in
      do {
        try await BundledControllerSkins.installIfNeededInBackground()
      } catch {
        NSLog("Bundled controller skin could not be installed: %@", error.localizedDescription)
      }
    }
    #endif
    // No game is running at launch, so a Live Activity still on screen belongs to a run that was
    // killed before it could end it.
    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    GameActivityManager.end()
    #endif
    return started
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

  // Silent CloudKit pushes for iCloud sync (CloudSyncPushService). CloudKit keeps its own device token.
  func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {}

  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    CloudSyncPushService.shared.didFailToRegister(error)
  }

  func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                   fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    CloudSyncPushService.shared.receive(userInfo, completion: completionHandler)
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

  /// A remote-library game download finished while iCube was suspended or not running.
  func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                   completionHandler: @escaping () -> Void) {
    if !BackgroundGameDownloader.shared.handleEvents(forSession: identifier, completion: completionHandler) {
      completionHandler()
    }
  }
}
