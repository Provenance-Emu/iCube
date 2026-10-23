// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import os
import SwiftUI
import UIKit

/// What the phone's DSU controller screen does with its server when the app changes scene phase.
/// iOS suspends the app's sockets in the background, so the server is stopped there and brought
/// back once the app is active again with the controller screen still open.
enum DSUSessionLifecycle {
  enum Action: Equatable {
    case start
    case stop
    case none
  }

  /// The phone's DSU server log: scene changes and what they did to the server.
  static let log = ICubeLog.logger("DSU")

  static func action(for phase: ScenePhase, serverRunning: Bool, sessionOpen: Bool) -> Action {
    switch phase {
    case .background:
      return serverRunning ? .stop : .none
    case .active:
      return (sessionOpen && !serverRunning) ? .start : .none
    default:
      return .none
    }
  }
}

extension View {
  /// The app going to the background and coming back, as scene phases. The window's root is a
  /// `UIHostingController` (`MainDisplaySceneDelegate`), not a SwiftUI `App`, so
  /// `@Environment(\.scenePhase)` never changes there: these come from the UIApplication notifications.
  /// Coming back is `willEnterForeground`, so a Control Center or notification dip does not count.
  func onAppLifecycle(_ action: @escaping (ScenePhase) -> Void) -> some View {
    onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
      action(.background)
    }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
      action(.active)
    }
  }
}
