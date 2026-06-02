// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

@objc class UserFolderUtil: NSObject {
  @objc static func getUserFolder() -> String {
    #if NONJAILBROKEN || TROLLSTORE || APPSTORE
    #if os(tvOS)
    return NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0]
    #else // !tvOS
    return NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
    #endif
    #else
    return "/private/var/mobile/Documents/iCube"
    #endif
  }

  @objc static func getSoftwareFolder() -> String {
    return getUserFolder().stringByAppendingPathComponent("Software")
  }
}
