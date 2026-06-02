// Copyright 2023 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

@objcMembers class VersionManager: NSObject {
  private static let sharedInstance = VersionManager()

  class func shared() -> VersionManager {
    return sharedInstance
  }

  let appVersion: DOLAppVersion
  let coreVersion: String // "5.0-12345"

  override private init() {
    self.appVersion = DOLAppVersion()

    let info = Bundle.main.infoDictionary!

    self.coreVersion = info["DOLCoreVersion"] as! String
  }
}
