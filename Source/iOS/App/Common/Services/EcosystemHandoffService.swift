// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

/// Runs iCube's side of the drop box it shares with Provenance and iFly
/// (`EcosystemHandoff`): presence at launch, and on every activation presence
/// again, clean-up of its own stale sends, and the import of games a sibling
/// left in its inbox. The `dolphinios://handoff` wake-up reaches the same
/// import through `URLRouterService`.
final class EcosystemHandoffService: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    EcosystemHandoffImporter.publishPresence()
    return true
  }

  func applicationDidBecomeActive(_ application: UIApplication) {
    EcosystemHandoffImporter.appBecameActive()
  }
}
