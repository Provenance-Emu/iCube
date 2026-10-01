// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Load Profile…, pushed from the player screen (everything below the hub is a push). Picking a
/// profile loads it and pops back. Its own host, not a `.navigation` row: a `.navigation` child is
/// built once at push time and cannot pop itself after a pick.
struct ProfileListView: View {
  let current: String?
  /// Read during the first `body`, then cached on appear, never in `init`: the parent rebuilds this
  /// view on every render, and the list must not flash "No profiles" before its first read.
  let loadNames: () -> [String]
  let onPick: (String) -> Void

  @State private var names: [String]?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    MenuScreen(
      model: ProfileListModelBuilder.make(names: names ?? loadNames(), current: current, onPick: { name in
        onPick(name)
        dismiss()
      }),
      style: .list,
      onBack: { dismiss() })
      .navigationTitle(L("Load Profile"))
      .onAppear { if names == nil { names = loadNames() } }
  }
}

/// Pure: the profile names (user and bundled, as `TVControllerMappingBridge.profiles(forGCPort:)`
/// lists them) in case-insensitive order, the current one marked.
enum ProfileListModelBuilder {
  static func make(names: [String], current: String?, onPick: @escaping (String) -> Void) -> MenuModel {
    let sorted = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    guard !sorted.isEmpty else {
      // Enabled no-op: tvOS focus needs a row to land on.
      return MenuModel(sections: [
        MenuSection(id: "profiles", items: [MenuItem(id: "no-profiles", title: L("No profiles"), role: .action({}))]),
      ])
    }
    return MenuModel(sections: [
      MenuSection(id: "profiles", header: L("Profiles"), items: sorted.map { name in
        MenuItem(
          id: "profile-\(name)", title: name, icon: "doc.text",
          role: .action { onPick(name) }, badge: name == current ? L("Current") : nil)
      }),
    ])
  }
}
