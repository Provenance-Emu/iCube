// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The Controllers hub: the same screen from the pause menu, Settings and the top bar. The host
/// supplies the `NavigationStack`: every row below pushes into it.
///
/// Its state lives in a `@State` view model owned by this view, a real node in every host. No
/// presentation is attached inside the list, so nothing waits on a lazily built row (the old
/// "Profiles… only opens after a scroll" lockup).
@MainActor
struct ControllerHubView: View {
  private let onBack: (() -> Void)?

  @State private var viewModel: ControllerHubViewModel
  @Environment(\.dismiss) private var dismiss

  /// - Parameters:
  ///   - onBack: B (iOS) / Menu (tvOS) at the hub's root. nil pops or dismisses the hub. A host
  ///     that shows the hub as a pane rather than a push or sheet (the tvOS pause menu) must pass it.
  ///     `MenuScreen` handles tvOS Menu itself, so a nil handler would otherwise swallow it.
  init(system: ControllerSetupSystem, onBack: (() -> Void)? = nil) {
    self.onBack = onBack
    _viewModel = State(initialValue: ControllerHubViewModel(system: system))
  }

  var body: some View {
    MenuScreen(
      model: ControllerHubModelBuilder.make(state: viewModel.state, actions: viewModel.actions, platform: .current),
      style: .list,
      // Flush first: the host releases its pause claim right after this returns, and a change made
      // within the settle delay must land before the game resumes. `onDisappear` stays the backstop
      // for Done, Close and swipe-to-dismiss.
      onBack: {
        viewModel.flushPending()
        (onBack ?? { dismiss() })()
      }
    )
    // The menu has the request once this render is out; carrying it until then (not dropping it on
    // the next reload) is what lets a later reload in the same turn not lose it.
    .onChange(of: viewModel.state.focusRequest) { _, request in
      guard request != nil else { return }
      DispatchQueue.main.async { viewModel.consumeFocusRequest() }
    }
    .navigationTitle(L("Controllers"))
    // A pushed player screen covers this one: stop on disappear, reload on the way back.
    .onAppear { viewModel.start() }
    .onDisappear { viewModel.stop() }
    #if os(iOS)
    // Attached to the hub, not a row: nothing waits on a lazily built row (see above).
    .fullScreenCover(isPresented: $viewModel.isLayoutEditorPresented) {
      TouchOverlayLayoutEditorView(padKind: TouchOverlayLayoutEditorView.lastPadKind(), overGame: false) {
        viewModel.isLayoutEditorPresented = false
      }
    }
    .fullScreenCover(isPresented: $viewModel.isIRAreaEditorPresented) {
      TouchOverlayLayoutEditorView(mode: .irArea, padKind: .wiiRemote, overGame: false) {
        viewModel.isIRAreaEditorPresented = false
      }
    }
    #endif
  }
}
