// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import SwiftUI
import UIKit

private struct SettingsPaneBackKey: EnvironmentKey {
  static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
  /// Set by the sidebar shell on its pane: what Back means for a leaf shown in the pane (focus returns
  /// to the sidebar). `nil` outside the shell, where a leaf is pushed and Back pops it.
  var settingsPaneBack: (() -> Void)? {
    get { self[SettingsPaneBackKey.self] }
    set { self[SettingsPaneBackKey.self] = newValue }
  }
}

extension View {
  /// For a screen pushed from inside a sidebar pane. `settingsPaneBack` is inherited through the
  /// environment, so without this Back on a pushed sub-leaf would jump to the sidebar and leave the
  /// sub-leaf on the stack instead of popping it.
  func clearingSettingsPaneBack() -> some View {
    environment(\.settingsPaneBack, nil)
  }
}

/// What every engine-backed settings leaf needs around its `MenuScreen`: a title, the help sheet
/// button, and the same resync points the hand-built leaves had (`configSynced`, emulation start/
/// end, foreground). `sync` assigns the host's snapshot only; it never writes Config.
private struct SettingsLeafHost: ViewModifier {
  let title: String
  let helpKey: String?
  let sync: () -> Void

  /// Emulation start/end are posted from the emulation thread; `sync` writes host @State, which must
  /// happen on main.
  private static func onMain(_ name: Notification.Name) -> some Publisher<Notification, Never> {
    NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main)
  }

  func body(content: Content) -> some View {
    content
      .navigationTitle(title)
      .configSynced(sync)
      .onReceive(Self.onMain(.DOLEmulationDidStart)) { _ in sync() }
      .onReceive(Self.onMain(EmulationState.didEndName)) { _ in sync() }
      #if os(iOS)
      .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in sync() }
      #endif
      .toolbar {
        if let helpKey {
          HelpButton(helpKey: helpKey)
        }
      }
  }
}

extension View {
  /// Title, help sheet, Config sync on appear/Config change/emulation start+stop/foreground.
  func settingsLeaf(title: String, helpKey: String? = nil, sync: @escaping () -> Void) -> some View {
    modifier(SettingsLeafHost(title: title, helpKey: helpKey, sync: sync))
  }
}

/// A migrated leaf: its `MenuScreen` plus the host chrome. Back (a pad's B on iOS, Menu on tvOS) goes to
/// the sidebar when the shell supplies `settingsPaneBack`, and pops/dismisses otherwise. Without
/// `onBack` the pad's B did nothing on a pushed leaf, so a pad could push a leaf and never leave it.
struct SettingsLeafScreen: View {
  let model: MenuModel
  let title: String
  let helpKey: String?
  let sync: () -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(\.settingsPaneBack) private var paneBack

  init(model: MenuModel, title: String, helpKey: String? = nil, sync: @escaping () -> Void) {
    self.model = model
    self.title = title
    self.helpKey = helpKey
    self.sync = sync
  }

  /// What Back does: the shell's pane action when there is one, the environment dismiss otherwise.
  static func backAction(paneBack: (() -> Void)?, dismiss: @escaping () -> Void) -> () -> Void {
    paneBack ?? dismiss
  }

  var body: some View {
    MenuScreen(model: model, style: .list, onBack: Self.backAction(paneBack: paneBack, dismiss: { dismiss() }))
      .settingsLeaf(title: title, helpKey: helpKey, sync: sync)
  }
}
