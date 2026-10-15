// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

/// Entry points of the disc patching flow.
enum DiscPatchFlow {
  /// `launch(path:)` posts `.DOLLaunchGameAtPath`; the library screen boots the disc in response.
  static let launchPathKey = "filePath"
  private static let launchIDKey = "launchID"

  /// Opens the "Apply Patch" sheet.
  ///
  /// - Parameters:
  ///   - patchURLs: Patch files to offer. One file is selected straight away; several are listed to
  ///     pick from; none opens the sheet at "choose a patch" (a file picker on iOS, the patches
  ///     already on the device on tvOS). Files outside `<User>/Patches/` are copied there.
  ///   - suggestedGameID: A game ID (for example the one a mod page is for) whose library disc is
  ///     preselected and ranked first. nil lets the sheet guess from the patch.
  ///   - presenter: The view controller to present from. nil presents over the top-most view
  ///     controller of the active scene, which is what a SwiftUI context menu or the mod browser want.
  ///     The sheet is a modal `UIHostingController`; it cannot be dismissed by swipe while a job runs.
  @MainActor
  static func present(patchURLs: [URL], suggestedGameID: String?, from presenter: UIViewController? = nil) {
    guard let directories = DiscPatchDirectories.live,
          let host = presenter ?? topViewController() else { return }
    let model = DiscPatchModel(patchURLs: patchURLs, suggestedGameID: suggestedGameID, directories: directories)
    let controller = UIHostingController(rootView: DiscPatchSheet(model: model))
    #if os(iOS)
    controller.modalPresentationStyle = .pageSheet
    #endif
    model.dismiss = { [weak controller] in controller?.dismiss(animated: true) }
    host.present(controller, animated: true)
  }

  /// Boots a disc that is not in the library (a cached patched copy) through the library screen, so it
  /// gets the normal emulation screen, profile and "a game is running" handling.
  nonisolated static func launch(path: String) {
    NotificationCenter.default.post(name: .DOLLaunchGameAtPath, object: nil,
                                    userInfo: [launchPathKey: path, launchIDKey: UUID().uuidString])
  }

  private static let claimLock = NSLock()
  private static var lastClaimedLaunch: String?

  /// The library item for a `launch(path:)` request, handed to the first observer only. Every
  /// appearance of the library screen adds an observer and none is removed, so without this one
  /// request would start the game once per observer.
  nonisolated static func claimLaunch(_ note: Notification) -> TVGameItem? {
    guard let path = note.userInfo?[launchPathKey] as? String,
          let id = note.userInfo?[launchIDKey] as? String else { return nil }
    claimLock.lock()
    defer { claimLock.unlock() }
    guard lastClaimedLaunch != id else { return nil }
    lastClaimedLaunch = id
    return DiscImageBridge.gameItem(forPath: path)
  }

  @MainActor
  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    guard let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first,
          var top = window.rootViewController else { return nil }
    while let presented = top.presentedViewController { top = presented }
    return top
  }
}
