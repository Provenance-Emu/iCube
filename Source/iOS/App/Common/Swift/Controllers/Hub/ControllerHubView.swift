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
  private let prepare: () -> Void

  @State private var viewModel: ControllerHubViewModel
  @Environment(\.dismiss) private var dismiss

  /// - Parameters:
  ///   - onBack: B (iOS) / Menu (tvOS) at the hub's root. nil pops or dismisses the hub. A host
  ///     that shows the hub as a pane rather than a push or sheet (the tvOS pause menu) must pass it.
  ///     `MenuScreen` handles tvOS Menu itself, so a nil handler would otherwise swallow it.
  ///   - prepare: runs on every appear, before the first read (Settings uses it to turn Player 1 on).
  init(system: ControllerSetupSystem, onBack: (() -> Void)? = nil, prepare: @escaping () -> Void = {}) {
    self.onBack = onBack
    self.prepare = prepare
    _viewModel = State(initialValue: ControllerHubViewModel(system: system))
  }

  var body: some View {
    MenuScreen(
      model: ControllerHubModelBuilder.make(state: viewModel.state, actions: viewModel.actions, platform: .current),
      style: .list,
      onBack: onBack ?? { dismiss() }
    )
    .navigationTitle(L("Controllers"))
    // A pushed player screen covers this one: stop on disappear, reload on the way back.
    .onAppear {
      prepare()
      viewModel.start()
    }
    .onDisappear { viewModel.stop() }
  }
}
