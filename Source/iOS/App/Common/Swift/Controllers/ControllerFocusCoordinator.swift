// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Arbitrates which on-screen surface "owns" the game controller for APP-UI
/// navigation.
///
/// `GCControllerButtonInput.pressedChangedHandler` and
/// `GCExtendedGamepad.valueChangedHandler` are **single-slot** properties on a
/// process-wide shared controller list. Several surfaces (the library grid, the
/// pause menu, modals) install raw handlers on them, last writer wins, and
/// `onDisappear` does NOT fire for a view that is merely *covered* by a sheet or
/// a `fullScreenCover`. So a covered surface's handlers keep firing underneath
/// whatever is on top of it, and a stale "swallow" closure can outlive the
/// screen that installed it. That, not any contest with the emulator core, was
/// the real collision: Dolphin's `ciface::iOS::MFiController` installs no
/// handlers at all — it polls `.isPressed` per frame — so the core and the
/// Swift wrapper never fight over a handler slot. Swift fights itself.
///
/// This is a LIFO **scope stack**. Each controller-consuming surface pushes a
/// scope while it is on screen and pops it when it leaves; the topmost scope is
/// the sole owner. Surfaces keep their raw handlers installed and self-gate on
/// `isActive(myScope)`, so a covering surface silences the covered one even
/// though the covered one never received an `onDisappear`.
///
/// This governs app-UI navigation only. In-game input is unaffected: Dolphin
/// polls the controller directly, and the Menu/Options pause route
/// (`installPauseMenuHandlers`) gates on emulation running rather than on scope.
@MainActor
final class ControllerFocusCoordinator: ObservableObject {
  static let shared = ControllerFocusCoordinator()

  /// The currently-active scope (top of the stack), published so views can
  /// react — e.g. hide a focus ring when they are no longer the owner.
  @Published private(set) var activeScope: UUID?

  private var stack: [UUID] = []

  /// Non-isolated mirror of the top of the stack.
  ///
  /// Raw `GCController` handlers are invoked on GameController's own queue, not
  /// the main actor, so they cannot touch `activeScope` directly. This is
  /// written only from `push`/`pop` (both main-actor) and read as a plain
  /// value, which is why the unchecked annotation is sound here.
  nonisolated(unsafe) private static var activeScopeMirror: UUID?

  /// Main-actor-free scope check for raw controller handlers.
  nonisolated static func isActiveScope(_ id: UUID) -> Bool {
    activeScopeMirror == id
  }

  private init() {}

  /// Make `id` the active owner. Idempotent: re-pushing an id already in the
  /// stack moves it to the top, which handles out-of-order appear/disappear.
  func push(_ id: UUID) {
    stack.removeAll { $0 == id }
    stack.append(id)
    activeScope = stack.last
    Self.activeScopeMirror = stack.last
  }

  /// Remove `id` wherever it sits, not just from the top, so a disappear that
  /// arrives after a newer surface already pushed still cleans up.
  func pop(_ id: UUID) {
    stack.removeAll { $0 == id }
    activeScope = stack.last
    Self.activeScopeMirror = stack.last
  }

  /// True when `id` is the topmost (owning) scope.
  func isActive(_ id: UUID) -> Bool {
    stack.last == id
  }
}

// MARK: - View integration

private struct ControllerScopeClaim: ViewModifier {
  /// Stable per-modifier-instance id when no explicit one is supplied.
  @State private var generated = UUID()
  let explicit: UUID?

  private var id: UUID { explicit ?? generated }

  func body(content: Content) -> some View {
    content
      .onAppear { ControllerFocusCoordinator.shared.push(id) }
      .onDisappear { ControllerFocusCoordinator.shared.pop(id) }
  }
}

extension View {
  /// Claim controller ownership while this view is on screen. Use on modal /
  /// cover / sheet content that should silence the controller handlers of
  /// whatever it is presented over — even when that surface never receives an
  /// `onDisappear`.
  func claimsController() -> some View {
    modifier(ControllerScopeClaim(explicit: nil))
  }

  /// Bind an EXPLICIT scope id to this view's on-screen lifetime, for surfaces
  /// that keep their own raw `GCController` handlers and self-gate on
  /// `ControllerFocusCoordinator.shared.isActive(id)`.
  func controllerScope(_ id: UUID) -> some View {
    modifier(ControllerScopeClaim(explicit: id))
  }
}
