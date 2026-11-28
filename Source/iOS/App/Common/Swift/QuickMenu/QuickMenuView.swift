// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Where the pause menu opens when the quick menu hands over to it.
enum QuickMenuHandoff: Equatable {
  case menu, shaders, exitConfirm
  /// Not the pause menu: the TV switcher strip, over the paused game.
  case bezels
}

/// The quick menu (spec §7): a two-row tile panel at the bottom of the screen over the dimmed game.
/// It holds a `PauseArbiter` claim while it is up, so the core pauses and resumes through the arbiter only.
/// Present it as an overlay, never a `fullScreenCover`, so the game stays visible behind the scrim.
struct QuickMenuView: View {
  /// Opacity of the scrim that dims the game behind the panel.
  private static let scrimOpacity = 0.35

  @Binding var isPresented: Bool
  /// A TV could be drawn around the picture right now, so the Bezels tile is offered.
  let showsBezels: Bool
  let bindings: PauseMenuBindings
  let actions: PauseMenuActions
  /// Opens the full pause menu; `.shaders` and `.exitConfirm` open it on that screen.
  let onOpenPauseMenu: (QuickMenuHandoff) -> Void

  @State private var token: PauseArbiter.Token?

  init(isPresented: Binding<Bool>, showsBezels: Bool = false, bindings: PauseMenuBindings, actions: PauseMenuActions,
       onOpenPauseMenu: @escaping (QuickMenuHandoff) -> Void) {
    _isPresented = isPresented
    self.showsBezels = showsBezels
    self.bindings = bindings
    self.actions = actions
    self.onOpenPauseMenu = onOpenPauseMenu
  }

  /// A snapshot built from the live bindings, so the Mute icon and the slot badge follow them.
  private var state: PauseMenuState {
    PauseMenuState(quickSlot: bindings.quickSlot.wrappedValue as? Int ?? 1, isMuted: bindings.mute.wrappedValue,
                   activeCheatCount: 0, shaderOptions: QuickMenuHost.shaderOptions(), showsRecenterPointer: false,
                   quickSaveMode: bindings.quickSaveMode.wrappedValue, isModded: ModdedBoot.isCurrentBootModded, showsBezels: showsBezels)
  }

  private var model: MenuModel {
    var routed = actions
    routed.openShaders = { openPauseMenu(.shaders) }
    routed.requestExit = { openPauseMenu(.exitConfirm) }
    routed.openBezels = { openPauseMenu(.bezels) }
    return QuickMenuModelBuilder.make(
      state: state, bindings: bindings, actions: routed,
      extras: QuickMenuExtras(aspect: QuickMenuHost.aspectBinding(), openMenu: { openPauseMenu(.menu) }))
  }

  /// Hands the pause over. The host claims first (a pending token the pause menu adopts), so releasing
  /// ours never lets the core resume in between.
  private func openPauseMenu(_ handoff: QuickMenuHandoff) {
    onOpenPauseMenu(handoff)
    releaseClaim()
    isPresented = false
  }

  private func releaseClaim() {
    guard let held = token else { return }
    token = nil
    PauseArbiter.shared.release(held)
  }

  var body: some View {
    ZStack {
      Color.black.opacity(Self.scrimOpacity).ignoresSafeArea()
      MenuScreen(model: model, style: .tiles(columns: QuickMenuModelBuilder.columns, compact: true), onBack: { isPresented = false })
        .icubePanel()
        .padding(ICubeDesign.Spacing.xl.rawValue)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
    .onAppear {
      // Before the claim, as the pause menu does: the Screenshot tile and the quick-save thumbnail read
      // this frame, and nothing else refreshes it while the panel is up.
      SaveStateService.capturePausePreview()
      if token == nil { token = PauseArbiter.shared.claim(PauseArbiter.Reason.quickMenu) }
    }
    .onDisappear { releaseClaim() }
  }
}

#if DEBUG
/// `-ICubeQuickMenuPreview`: the quick menu over a stand-in room, for simulator screenshots. Its tiles
/// that need a running game do nothing.
struct QuickMenuAuditPreview: View {
  @State private var isPresented = true
  @State private var slot = 1
  @State private var mode = QuickSaveMode.history
  @State private var lastAction = "Ready"

  var body: some View {
    ZStack {
      ICubeRoom(style: .gradient)
      Text(lastAction).icubeText(.detail).accessibilityIdentifier("quick-preview.last-action")
      if isPresented {
        QuickMenuView(
          isPresented: $isPresented,
          showsBezels: true,
          bindings: QuickMenuHost.bindings(selectedSlot: $slot, mode: $mode),
          actions: PauseMenuActions(
            resume: {}, quickSave: { lastAction = "quick-save" }, quickLoad: { lastAction = "quick-load" },
            screenshot: { lastAction = "screenshot" }, openSaveStates: {}, openCheats: {}, openControllers: {},
            openShaders: {}, openContinuity: {}, openSettings: {}, openPerfOverlay: { lastAction = "performance" },
            requestReset: {}, requestExit: {}, recenterPointer: {}),
          onOpenPauseMenu: { lastAction = "handoff.\($0)" })
      }
    }
  }
}
#endif
