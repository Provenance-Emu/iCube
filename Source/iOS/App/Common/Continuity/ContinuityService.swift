// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVWebServer
import UIKit

/// Registers the continuity routes at launch.
///
/// Registration is independent of the web server's listener: routes registered
/// while the server is stopped are live the moment it binds, and they survive
/// the stop/start cycle `WebServerLifecycleService` drives. So this can (and
/// must) run before anything has started listening — there is no ordering
/// dependency between the two services to get wrong.
final class ContinuityService: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        MainActor.assumeIsolated {
            ContinuityManager.shared.registerRoutes(on: PVWebServer.shared)
        }
        return true
    }

    /// Close any live session on the way out. A session that outlives the app
    /// would leave a Bonjour record advertising a device that answers nothing.
    func applicationWillTerminate(_ application: UIApplication) {
        MainActor.assumeIsolated {
            Task { await ContinuityManager.shared.endHandoff() }
        }
    }
}
