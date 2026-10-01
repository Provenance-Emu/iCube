// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import GameController
import SwiftUI

/// B on a controller pops a pushed screen that is not a `MenuScreen` (iOS). `MenuScreen` handles B
/// itself; a plain `List`/`Form` pushed from one (More Controller Settings, Motion Source (DSU),
/// Edit Layout) had no pad Back at all, so a pad's A could push it and nothing brought the pad back.
/// tvOS needs nothing: Menu pops natively.
///
/// Same machinery as `MenuScreen`: polled at 60 Hz, one latch per pad through `MenuFocusRouter` (a
/// pad's first tick is a resync, so the A still held from the push never counts), gated on this
/// screen's own `ControllerFocusCoordinator` scope.
///
/// Apply it to the pushed view itself, never to a view that hosts its own `MenuScreen`: both would
/// then claim a scope, and which one ends up on top depends on `onAppear` order.
private struct PadBackNavigation: ViewModifier {
  #if os(iOS)
  @Environment(\.dismiss) private var dismiss
  @State private var router = MenuFocusRouter()
  @State private var scopeID = UUID()
  private static let tick = Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()
  #endif

  func body(content: Content) -> some View {
    #if os(iOS)
    content
      .controllerScope(scopeID)
      .onReceive(Self.tick) { _ in poll() }
    #else
    content
    #endif
  }

  #if os(iOS)
  private func poll() {
    let pads: [(AnyHashable, MenuControllerNav.Input)] = GCController.controllers().compactMap { controller in
      guard let pad = controller.extendedGamepad else { return nil }
      return (AnyHashable(ObjectIdentifier(controller)), MenuControllerNav.Input(b: pad.buttonB.isPressed))
    }
    guard !pads.isEmpty else { return }
    let result = router.update(
      padInputs: pads, at: CACurrentMediaTime(), model: MenuModel(), focusedID: nil,
      isActive: ControllerFocusCoordinator.isActiveScope(scopeID))
    if result.didGoBack { dismiss() }
  }
  #endif
}

extension View {
  /// B pops this pushed screen on iOS. For pushed screens that are not a `MenuScreen`.
  func padBackNavigation() -> some View {
    modifier(PadBackNavigation())
  }
}
