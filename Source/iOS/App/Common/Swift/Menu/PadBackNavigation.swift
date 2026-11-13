// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import GameController
import SwiftUI

/// B on a controller pops a pushed screen that is not a `MenuScreen` (iOS). `MenuScreen` handles B
/// itself; a plain `List`/`Form` pushed from one (Controller Lights, Motion Source (DSU),
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
  @Environment(\.menuTabSwitch) private var tabSwitch
  @State private var router = MenuFocusRouter()
  @State private var scopeID = UUID()
  @State private var pollThrottle = PadPollThrottle()
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
    guard pollThrottle.shouldRun(at: CACurrentMediaTime(), emulating: PadPollThrottle.gameIsRunning) else { return }
    let pads: [(AnyHashable, MenuControllerNav.Input)] = ControllerManager.shared.controllers.compactMap { controller in
      guard let pad = controller.extendedGamepad else { return nil }
      return (AnyHashable(ObjectIdentifier(controller)), MenuControllerNav.Input(
        b: pad.buttonB.isPressed, leftTrigger: pad.leftTrigger.isPressed, rightTrigger: pad.rightTrigger.isPressed))
    }
    guard !pads.isEmpty else { return }
    let result = router.update(
      padInputs: pads, at: CACurrentMediaTime(), model: MenuModel(), focusedID: nil,
      isActive: ControllerFocusCoordinator.isActiveScope(scopeID))
    if result.didGoBack { dismiss() }
    // The triggers change tab from any page, a plain one included.
    if result.tabSwitch != 0 { tabSwitch?(result.tabSwitch) }
  }
  #endif
}

private struct MenuTabSwitchKey: EnvironmentKey {
  static let defaultValue: ((Int) -> Void)? = nil
}

extension EnvironmentValues {
  /// A pad's L2 / R2 on iOS: steps the host to its previous (-1) or next (+1) tab. Set by a host that
  /// has tabs a pad cannot otherwise reach (the Settings sidebar on iPad, whose rows are touch
  /// targets); nil elsewhere, and the triggers then do nothing in a menu.
  var menuTabSwitch: ((Int) -> Void)? {
    get { self[MenuTabSwitchKey.self] }
    set { self[MenuTabSwitchKey.self] = newValue }
  }
}

/// The tab a trigger lands on: the neighbour of `current` in `ids`, wrapping at both ends so one
/// trigger alone reaches every tab. The first (or last) tab when nothing is selected.
enum MenuTabStep {
  static func target(from current: String?, by step: Int, in ids: [String]) -> String? {
    guard !ids.isEmpty, step != 0 else { return current }
    guard let current, let index = ids.firstIndex(of: current) else { return step > 0 ? ids.first : ids.last }
    return ids[((index + step) % ids.count + ids.count) % ids.count]
  }
}

extension View {
  /// B pops this pushed screen on iOS. For pushed screens that are not a `MenuScreen`.
  func padBackNavigation() -> some View {
    modifier(PadBackNavigation())
  }
}
