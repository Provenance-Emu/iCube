// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// What the phone's DSU controller screen does with its server when the app changes scene phase.
/// iOS suspends the app's sockets in the background, so the server is stopped there and brought
/// back once the app is active again with the controller screen still open.
enum DSUSessionLifecycle {
  enum Action: Equatable {
    case start
    case stop
    case none
  }

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
