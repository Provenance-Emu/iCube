// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import UIKit

@MainActor
class ServiceManager {
  static let shared = ServiceManager()

  var application: UIApplication?

  #if os(tvOS) || targetEnvironment(macCatalyst)
  let services: [UIApplicationDelegate] = [
    DefaultsInitService(),
    DolphinCoreService(),
    FirstRunInitializationService(),
    LegacyInputConfigMigrationService(),
    GameFileCacheService(),
    JitAcquisitionService(),
    URLRouterService(),
    AudioSessionCategoryService(),
//    UpdateCheckService()
  ]
  #else
  let services: [UIApplicationDelegate] = [
    DefaultsInitService(),
    DolphinCoreService(),
    FirstRunInitializationService(),
    LegacyInputConfigMigrationService(),
    GameFileCacheService(),
    JitAcquisitionService(),
    URLRouterService(),
    SpotlightIndexService(),
    FirebaseService(),
    AudioSessionCategoryService(),
//    UpdateCheckService()
  ]
  #endif

  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    self.application = application

    var returnedResult: Bool = true

    for service in services {
      let result = service.application?(application, didFinishLaunchingWithOptions: launchOptions) ?? true

      if !result {
        returnedResult = false
      }
    }

    return returnedResult
  }

  func applicationWillTerminate() {
    for service in services {
      service.applicationWillTerminate?(application!)
    }
  }

  func applicationDidBecomeActive() {
    for service in services {
      service.applicationDidBecomeActive?(application!)
    }
  }

  func applicationWillResignActive() {
    for service in services {
      service.applicationWillResignActive?(application!)
    }
  }

  func applicationDidEnterBackground() {
    for service in services {
      service.applicationDidEnterBackground?(application!)
    }
  }

  func applicationDidReceiveMemoryWarning() {
    for service in services {
      service.applicationDidReceiveMemoryWarning?(application!)
    }
  }

  func open(url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    var returnedResult: Bool = true

    for service in services {
      let result = service.application?(application!, open: url, options: options) ?? true

      if !result {
        returnedResult = false
      }
    }

    return returnedResult
  }
}
