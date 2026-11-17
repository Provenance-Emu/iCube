// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if targetEnvironment(macCatalyst)
import Combine
import UIKit

/// Mac only. Owns the menu-bar item and decides what happens when the last window closes, so a
/// desktop install can keep sharing its library on the local network with no window open.
/// The rules live in `DesktopPresence`; AppKit is reached through `ICMacAppKitBridge`.
@MainActor
final class MacDesktopController {
  static let shared = MacDesktopController()

  private static let statusSymbolName = "gamecontroller.fill"
  private static let appName = "iCube"
  /// Long enough for a newly opened window to mount the library's notification observers; the same
  /// delay the scene delegate uses for cold-launch links.
  private static let windowMountDelay: TimeInterval = 0.6

  private var cancellables: Set<AnyCancellable> = []
  private var observers: [NSObjectProtocol] = []
  private var backgroundActivity: NSObjectProtocol?
  private var sharingLibrary = false
  private var hasMenuBarItem = false
  private var started = false
  private var terminating = false

  private var keepRunning: Bool {
    get { UserDefaults.standard.bool(forKey: DesktopPresence.keepRunningDefaultsKey) }
    set { UserDefaults.standard.set(newValue, forKey: DesktopPresence.keepRunningDefaultsKey) }
  }

  func start() {
    guard !started else { return }
    started = true
    UserDefaults.standard.register(defaults: [DesktopPresence.keepRunningDefaultsKey: true])
    hasMenuBarItem = ICMacAppKitBridge.installStatusItem(withSymbolName: Self.statusSymbolName, toolTip: Self.appName)

    sharingLibrary = ContinuityManager.shared.sharesLibrary
    ContinuityManager.shared.$sharesLibrary
      .sink { [weak self] shares in
        Task { @MainActor in self?.sharingChanged(to: shares) }
      }
      .store(in: &cancellables)

    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { [weak self] note in
      let closed = (note.object as? UIScene).map(ObjectIdentifier.init)
      Task { @MainActor in self?.sceneDidDisconnect(closed) }
    })
    observers.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.terminating = true }
    })
    refresh()
  }

  // MARK: - Windows

  private func mainWindowScenes(excluding closed: ObjectIdentifier? = nil) -> [UIWindowScene] {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .filter { $0.session.role == .windowApplication && ObjectIdentifier($0) != closed }
  }

  var hasMainWindow: Bool { !mainWindowScenes().isEmpty }

  /// Brings the app forward and makes sure it has a window, reusing the closed window's session
  /// when the system kept one so its size and position come back.
  func openMainWindow() {
    ICMacAppKitBridge.activateApp()
    let application = UIApplication.shared
    let session = mainWindowScenes().first?.session
      ?? application.openSessions.first { $0.role == .windowApplication }
    let request = session.map { UISceneSessionActivationRequest(session: $0) }
      ?? UISceneSessionActivationRequest(role: .windowApplication)
    application.activateSceneSession(for: request) { error in
      NSLog("iCube: could not open the main window: %@", error.localizedDescription)
    }
  }

  /// Posts a library notification (Import Game, Settings), opening the window first when there is none.
  func showLibrary(thenPost name: String) {
    let post = { NotificationCenter.default.post(name: NSNotification.Name(name), object: nil) }
    if hasMainWindow {
      ICMacAppKitBridge.activateApp()
      post()
    } else {
      openMainWindow()
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.windowMountDelay, execute: post)
    }
  }

  private func sceneDidDisconnect(_ closed: ObjectIdentifier?) {
    guard !terminating, mainWindowScenes(excluding: closed).isEmpty else { return }
    let decision = DesktopPresence.afterLastWindowCloses(
      keepRunning: keepRunning, gameRunning: TVEmulationBridge.isRunning(), hasMenuBarItem: hasMenuBarItem)
    switch decision {
    case .stayInMenuBar:
      refresh()
    case .quit:
      terminating = true
      ICMacAppKitBridge.terminateApp()
    }
  }

  // MARK: - Menu

  private func sharingChanged(to shares: Bool) {
    sharingLibrary = shares
    refresh()
  }

  private func refresh() {
    updateBackgroundActivity()
    guard hasMenuBarItem else { return }
    let rows = DesktopPresence.menu(sharingLibrary: sharingLibrary, keepRunning: keepRunning)
    ICMacAppKitBridge.setStatusMenuEntries(rows.map { row in
      switch row {
      case .separator:
        return ICMacMenuEntry.separator()
      case .status(let text):
        return ICMacMenuEntry(title: text, checked: false, handler: nil)
      case .action(let action, let title, let checked):
        return ICMacMenuEntry(title: title, checked: checked) { [weak self] in self?.perform(action) }
      }
    })
  }

  private func perform(_ action: DesktopPresence.MenuAction) {
    switch action {
    case .openWindow:
      openMainWindow()
    case .toggleSharing:
      let shares = !sharingLibrary
      Task { await ContinuityManager.shared.setSharesLibrary(shares) }
    case .toggleKeepRunning:
      keepRunning.toggle()
      refresh()
    case .quit:
      terminating = true
      ICMacAppKitBridge.terminateApp()
    }
  }

  /// Holds macOS off App Nap while other devices can ask this Mac for games. The Mac may still sleep.
  private func updateBackgroundActivity() {
    let needed = DesktopPresence.needsBackgroundActivity(sharingLibrary: sharingLibrary)
    if needed, backgroundActivity == nil {
      backgroundActivity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep,
        reason: "Sharing the game library on the local network")
    } else if !needed, let activity = backgroundActivity {
      ProcessInfo.processInfo.endActivity(activity)
      backgroundActivity = nil
    }
  }
}
#endif
