// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreSpotlight
import QuartzCore
import SwiftUI
import UIKit

class MainDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  #if !os(tvOS)
  private var pendingShortcutItem: UIApplicationShortcutItem?
  #endif

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    #if targetEnvironment(macCatalyst)
    // The Mac build allows more than one scene only so it can outlive its window (see
    // MacDesktopController). A second library window is closed again before it shows anything.
    if let current = MainSceneCoordinator.shared().mainScene, current !== scene {
      UIApplication.shared.requestSceneSessionDestruction(session, options: nil, errorHandler: nil)
      return
    }
    #endif
    MainSceneCoordinator.shared().mainScene = scene as? UIWindowScene
    // iCube: bring the perf test-bench server up at scene connect (not only at the first game boot)
    // so a Mac-side script can drive POST /api/debug/boot on a freshly launched app. Self-gated on
    // the "Perf Test Bench (HTTP)" toggle and idempotent, so this is a no-op for everyone else.
    DebugServerManager.shared.start()

    // On tvOS, we do not use storyboards. Create the window and root UI programmatically using SwiftUI.
    if AppConsts.useSwiftUI {
      guard let windowScene = scene as? UIWindowScene else { return }
      let window = UIWindow(windowScene: windowScene)
      let rootView = TVRootView()
      window.rootViewController = UIHostingController(rootView: rootView)
      #if DEBUG
      // `-ICubeAppearance light|dark` pins the appearance for simulator screenshots
      // (Scripts/tvos_screens.sh): the tvOS runtime rejects `simctl ui appearance`.
      if let style = TVRootView.argument(after: "-ICubeAppearance", in: ProcessInfo.processInfo.arguments) {
        window.overrideUserInterfaceStyle = style == "light" ? .light : .dark
      }
      #endif
      // Apply global tint from asset catalog (DolphinTint)
      if let tint = UIColor(named: "DolphinTint") {
        window.tintColor = tint
      }
      self.window = window
      window.makeKeyAndVisible()
      applyFrameCap(to: windowScene)
      // Start the universal controller observer at the app/scene root so hotplug
      // auto-assign is live in library, menus, and in-game on iOS and tvOS — not
      // only from the in-game screen. startObserving() is idempotent.
      ControllerManager.shared.startObserving()

      // Cold launch from a URL (Top Shelf tile, dolphinios:// link). Give the library
      // view time to mount its DOLLaunchGameByGameID observer, same delay as shortcuts.
      let openedURLs = connectionOptions.urlContexts.map(\.url)
      if !openedURLs.isEmpty {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
          self?.handleOpenedURLs(openedURLs)
        }
      }
      // Cold launch from an https://icube-emu.com universal link, delayed like the URL above.
      if let activity = connectionOptions.userActivities.first(where: { UniversalLinkRouter.customSchemeURL(for: $0) != nil }) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
          _ = self?.handleWebLink(activity)
        }
      }
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
    // Only the scene that is the main one: a refused second window disconnects too.
    if MainSceneCoordinator.shared().mainScene === scene {
      MainSceneCoordinator.shared().mainScene = nil
    }
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    handleOpenedURLs(URLContexts.map(\.url))
  }

  /// Game files the system asked the app to open (Open With, AirDrop, a drop on the Mac Dock icon)
  /// are imported together as one batch; everything else goes through `handleOpenedURL`.
  private func handleOpenedURLs(_ urls: [URL]) {
    #if os(iOS)
    let games = OpenedFileRouter.importableFiles(in: urls.filter { !SkinLibrary.isSkinArchive($0) })
    if !games.isEmpty {
      ImportFileManager.shared().importFiles(at: games as [NSURL])
    }
    let others = urls.filter { !games.contains($0) }
    #else
    let others = urls
    #endif
    others.forEach(handleOpenedURL)
  }

  /// One entry point for URLs opened warm (`openURLContexts`) and cold (`willConnectTo`).
  private func handleOpenedURL(_ url: URL) {
    #if os(iOS)
    if SkinLibrary.isSkinArchive(url) {
      importSkin(from: url)
      return
    }
    #endif
    _ = ServiceManager.shared.open(url: url, options: [:])
  }

  #if os(iOS)
  /// Installs a Delta / Manic skin the system handed us and reports the outcome in the snackbar.
  private func importSkin(from url: URL) {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let message: String
    do {
      let skin = try SkinLibrary.shared.importSkin(from: url)
      message = String(format: L("Imported skin %@"), skin.name)
    } catch {
      message = String(format: L("Couldn't import skin: %@"), SkinImportError.describe(error))
    }
    NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": message])
  }
  #endif

  func sceneDidBecomeActive(_ scene: UIScene) {
    ServiceManager.shared.applicationDidBecomeActive()
    // Consume a game id an App Intent (Siri/Shortcuts) queued while the app was launching.
    PendingGameLaunchStore.consumeAndLaunch()

    // Drop the inactive claim. The arbiter resumes the core only if nothing else (pause menu, Settings,
    // the user's pause, a disconnect) still holds it.
    PauseArbiter.shared.appDidBecomeActive()

    BootNoticeManager.shared().presentToSceneIfNecessary()
    if let ws = scene as? UIWindowScene { applyFrameCap(to: ws) }
  }

  func sceneWillResignActive(_ scene: UIScene) {
    // Pause emulation when another app/overlay takes over so the core stops submitting GPU
    // work from the background (which iOS rejects and floods the log) and to save battery.
    // A PauseArbiter claim, so the matching resume can never override another holder. First, so the
    // pause is queued ahead of the services' config write on the host queue.
    PauseArbiter.shared.appWillResignActive()

    ServiceManager.shared.applicationWillResignActive()
  }

  func sceneWillEnterForeground(_ scene: UIScene) {
    //
  }

  func sceneDidEnterBackground(_ scene: UIScene) {
    ServiceManager.shared.applicationDidEnterBackground()
    // Flush any pending in-memory Base config changes. Settings toggled in the menu write
    // Base via SetBaseOrCurrent, but most setters don't Save() per-toggle, so without this
    // a non-default toggle reverts to its launch default on the next launch.
    DOLConfigBridge.flushSettingsToDisk()
  }

  /// Routes a universal link onto the custom-scheme path. False for any other activity or an unknown link.
  private func handleWebLink(_ activity: NSUserActivity) -> Bool {
    guard let url = UniversalLinkRouter.customSchemeURL(for: activity) else { return false }
    handleOpenedURL(url)
    return true
  }

  func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    if handleWebLink(userActivity) { return }
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
    case QuickActionsUpdater.shortcutType:
      guard let gameID = shortcutItem.userInfo?["id"] as? String, !gameID.isEmpty else {
        completion(false)
        return
      }
      Task { @MainActor in GameLaunchRequest.launch(gameID: gameID) }
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

  private func applyFrameCap(to scene: UIWindowScene) {
    #if os(iOS)
    _ = UserDefaults.standard.integer(forKey: GraphicsGeneralDefaultsKey.frameCap)
    #endif
  }
}
