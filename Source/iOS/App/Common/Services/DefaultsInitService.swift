// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

class DefaultsInitService: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    // Create the Documents folder in case it doesn't exist. Do NOT force-try: a sandbox/permission
    // hiccup (e.g. NSCocoaErrorDomain 513) would crash the app at launch (ICUBE-H). Log and continue —
    // createDirectory(withIntermediateDirectories:) is a no-op if the folder already exists.
    let userFolder: String = UserFolderUtil.getUserFolder()
    let softwareFolder: String = UserFolderUtil.getSoftwareFolder()
    do {
      try FileManager.default.createDirectory(atPath: userFolder, withIntermediateDirectories: true, attributes: nil)
      try FileManager.default.createDirectory(atPath: softwareFolder, withIntermediateDirectories: true, attributes: nil)
    } catch {
      NSLog("[DefaultsInit] Could not create user/software folder: %@", error.localizedDescription)
    }

    // Exclude the software folder from iCloud backup. Best-effort; never fatal.
    var softwareResourceValues = URLResourceValues()
    softwareResourceValues.isExcludedFromBackup = true

    var softwareFolderUrl: URL = URL(fileURLWithPath: softwareFolder)
    do {
      try softwareFolderUrl.setResourceValues(softwareResourceValues)
    } catch {
      NSLog("[DefaultsInit] Could not set no-backup on software folder: %@", error.localizedDescription)
    }

    #if targetEnvironment(simulator)
    NSLog("User folder: %@", userFolder)
    #endif

    return true
  }
}
