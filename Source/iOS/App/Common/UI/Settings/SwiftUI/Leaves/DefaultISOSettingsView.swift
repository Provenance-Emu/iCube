// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Only local, already-inspected library discs get the action. Reopen the actual file when the
/// action runs, since it may have disappeared since the library scan. No disc IO in a card redraw.
enum DefaultISOLibraryAction {
  static func isOffered(for item: TVGameItem) -> Bool {
    guard !item.isDemoItem, item.filePath.hasPrefix("/"),
          FileManager.default.isReadableFile(atPath: item.filePath),
          let info = DiscImageBridge.info(forGameItem: item) else { return false }
    switch info.platform {
    case .gameCube, .triforce, .wii: return true
    default: return false
    }
  }
}

struct DefaultISOSelectionState: Equatable {
  var path = ""
  var available = false
  var name: String { path.isEmpty ? L("None") : URL(fileURLWithPath: path).lastPathComponent }
  static var instructions: String {
    L("Choose a local GameCube or Wii disc from its library context menu. This disc is mounted when booting homebrew launchers or the Wii Menu.")
  }
  static var unavailableMessage: String {
    L("The selected Default ISO is missing or unreadable. Select its new location in the library or clear it in General settings.")
  }
}

/// Pure management model; the path view is supplied by the host to preserve full-path readability.
enum DefaultISOSettingsModelBuilder {
  static func make(state: DefaultISOSelectionState, pathView: AnyView,
                   clear: @escaping () -> Void, done: @escaping () -> Void) -> MenuModel {
    let status = state.path.isEmpty ? L("No Default ISO selected") :
      (state.available ? DefaultISOSelectionState.instructions : DefaultISOSelectionState.unavailableMessage)
    var rows = [SettingsRow.caption("default-iso-status", status)]
    if !state.path.isEmpty {
      rows.append(SettingsRow.custom("default-iso-path", L("Default ISO"), pathView,
                                     state.path, enabled: false))
    }
    rows.append(SettingsRow.destructive("clear-default-iso", L("Clear Default ISO"),
                                         DefaultISOSelectionState.instructions, icon: "xmark.circle",
                                         enabled: !state.path.isEmpty, run: clear))
    #if os(tvOS)
    rows.append(SettingsRow.action("done", L("Done"), DefaultISOSelectionState.instructions, run: done))
    #endif
    return MenuModel(sections: [MenuSection(id: "default-iso", footer: DefaultISOSelectionState.instructions, items: rows)])
  }
}

struct DefaultISOSettingsView: View {
  @State private var state = DefaultISOSelectionState()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    SettingsLeafScreen(model: DefaultISOSettingsModelBuilder.make(state: state, pathView: AnyView(pathText), clear: clear, done: { dismiss() }),
                       title: L("Default ISO"), sync: sync)
  }

  private var pathText: some View {
    Text(verbatim: state.path)
      .icubeText(.body)
      .foregroundStyle(ICubeDesign.color(.textPrimary))
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("default-iso-path")
      #if os(iOS)
      .textSelection(.enabled)
      #endif
  }

  private func sync() {
    state = DefaultISOSelectionState(path: DOLConfigBridge.defaultISOSelectionPath(),
                                     available: DOLConfigBridge.defaultISOSelectionIsAvailable())
  }

  private func clear() {
    DOLConfigBridge.clearMainDefaultISO()
    sync()
  }
}
