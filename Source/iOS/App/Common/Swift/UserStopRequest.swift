// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

/// Shared by the pause menu and the in-game top bar. The stop callback keeps each surface's existing
/// save/lifecycle path; confirmation remains the safe default for a caller without a preference.
enum UserStopRequest {
  static func handle(confirmOnStop: Bool = true, confirm: () -> Void, stop: () -> Void) {
    if confirmOnStop { confirm() } else { stop() }
  }

  static func saveAndQuit(save: () -> String?, quit: (String) -> Void, failed: () -> Void) {
    guard let savedPath = save() else { failed(); return }
    quit(savedPath)
  }

  /// Save & Quit writes where a quick save would. In history mode that is a new history state:
  /// writing the selected numbered slot there replaced `{GameID}.s01` for people who had never
  /// chosen a slot. `mode` is the effective mode (`QuickSaveActions.effectiveMode`: a modded boot
  /// has no history and is always `.slots`). A failed save never falls back to the other kind.
  static func quitSavePath(mode: QuickSaveMode, history: () -> String?, slot: () -> String?) -> String? {
    switch mode {
    case .history: return history()
    case .slots: return slot()
    }
  }
}

enum UserQuitSaveFailure: Equatable, Sendable {
  /// The state Save & Quit writes first (a history state or the numbered slot) was not saved.
  case savingState
  case finalizing(savedStatePath: String?)
}

enum UserQuitFailureModelBuilder {
  static func make(cancel: @escaping () -> Void, retry: @escaping () -> Void,
                   quitWithoutSaving: @escaping () -> Void) -> MenuModel {
    MenuModel(sections: [MenuSection(id: "quit-save-failure", items: [
      MenuItem(id: "quit-failure-cancel", title: L("Cancel"), icon: "xmark", role: .action(cancel)),
      MenuItem(id: "quit-failure-retry", title: L("Retry"), icon: "arrow.clockwise", role: .action(retry)),
      MenuItem(id: "quit-without-saving", title: L("Quit Without Saving"), icon: "xmark.circle",
               tint: ICubeDesign.color(.destructive), role: .destructive(quitWithoutSaving)),
    ])])
  }
}

enum UserQuitAttemptResult: Sendable {
  case stopped
  case failed(UserQuitSaveFailure)
}
