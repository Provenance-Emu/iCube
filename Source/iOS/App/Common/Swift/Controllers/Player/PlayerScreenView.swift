// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// One player's controller screen (controller hub spec, "Player screen"), pushed from the hub's
/// player rows in place of `RemapPlayerView`. It hosts `PlayerScreenModelBuilder`'s model in a
/// `MenuScreen`, and everything below it pushes. Its only presentation is ONE alert, driven by the
/// view model's prompt and attached here, outside the List. A controller answers it through
/// `MenuScreen`'s `modal:`.
@MainActor
struct PlayerScreenView: View {
  @State private var viewModel: PlayerScreenViewModel
  /// The last non-nil prompt, kept while the alert animates out after `viewModel.prompt` clears, so
  /// its title (which `presenting:` does not scope) and message never blank.
  @State private var shownPrompt: PlayerPrompt?
  @Environment(\.dismiss) private var dismiss

  init(slot: PlayerSlot) {
    _viewModel = State(initialValue: PlayerScreenViewModel(slot: slot))
  }

  var body: some View {
    // The live prompt while there is one; the retained one while the alert closes.
    let alertPrompt = viewModel.prompt ?? shownPrompt
    MenuScreen(
      // `displayState`, not `state`: the first render (and tvOS's default focus) must not see the
      // empty snapshot that `start()` has not replaced yet.
      model: PlayerScreenModelBuilder.make(state: viewModel.displayState, actions: viewModel.actions, platform: .current),
      style: .list,
      onBack: {
        // While a capture is armed, B / Menu must reach the capture (so `Button B` stays bindable);
        // the 5 s timeout or the armed row cancels it. Just after a capture binds B, the same press
        // must not pop the screen either.
        if !viewModel.displayState.isCapturing && !viewModel.isCaptureSettling { dismiss() }
      },
      modal: modal)
      .navigationTitle(viewModel.slot.title)
      .alert(alertPrompt?.title ?? "", isPresented: isPromptShown, presenting: alertPrompt) { prompt in
        promptActions(prompt)
      } message: { prompt in
        Text(prompt.message)
      }
      .onChange(of: viewModel.prompt) { _, prompt in
        if let prompt { shownPrompt = prompt }
      }
      // A pushed list or editor covers this screen: stop on disappear, reload on the way back.
      .onAppear { viewModel.start() }
      .onDisappear { viewModel.stop() }
  }

  /// Shown while there is a prompt. An alert's own button runs `confirmPrompt` / `cancelPrompt`
  /// before SwiftUI sets this to false; the setter then cancels only the prompt this render showed,
  /// so a follow-up prompt (Replace, the save error), which arrives one main-actor hop later, is
  /// never cleared by the closing alert.
  private var isPromptShown: Binding<Bool> {
    let current = viewModel.prompt
    return Binding(
      get: { viewModel.prompt != nil },
      set: { if !$0, viewModel.prompt == current { viewModel.cancelPrompt() } })
  }

  @ViewBuilder
  private func promptActions(_ prompt: PlayerPrompt) -> some View {
    switch prompt {
    case .saveAs:
      // Prefilled (`openSavePrompt`), so a pad can save with A without typing.
      TextField(L("Name"), text: $viewModel.saveName)
      Button(L("Save")) { viewModel.confirmPrompt() }
      Button(L("Cancel"), role: .cancel) { viewModel.cancelPrompt() }
    case .confirmOverwrite, .confirmBuiltIn:
      Button(L("Replace"), role: .destructive) { viewModel.confirmPrompt() }
      Button(L("Cancel"), role: .cancel) { viewModel.cancelPrompt() }
    case .confirmReset:
      Button(L("Reset"), role: .destructive) { viewModel.confirmPrompt() }
      Button(L("Cancel"), role: .cancel) { viewModel.cancelPrompt() }
    case .saveFailed:
      Button(L("OK"), role: .cancel) { viewModel.cancelPrompt() }
    }
  }

  /// iOS controller input while something sits over the rows:
  /// - Any prompt: A confirms, B cancels (`MenuModal`).
  /// - An armed capture: the rows freeze and A/B do nothing to the menu, so the capture can bind
  ///   them. The latches keep tracking the pad, so the captured press never replays onto a row.
  private var modal: MenuModal? {
    if viewModel.prompt != nil {
      return MenuModal(onConfirm: { viewModel.confirmPrompt() }, onCancel: { viewModel.cancelPrompt() })
    }
    if viewModel.displayState.isCapturing {
      return MenuModal(onConfirm: {}, onCancel: {})
    }
    return nil
  }
}
