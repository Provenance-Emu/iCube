// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Load Profile…, pushed from the player screen (everything below the hub is a push). Picking a
/// profile loads it and pops back. Its own host, not a `.navigation` row: a `.navigation` child is
/// built once at push time and cannot pop itself after a pick.
///
/// Delete a Profile… switches the list into a delete mode, where picking one of the user's own
/// profiles asks before deleting it; bundled profiles are never offered. The question is this
/// screen's own alert (the player screen's alert sits under this push), answered by a pad through
/// `MenuScreen`'s `modal:` as the player screen's prompts are.
struct ProfileListView: View {
  let current: String?
  /// Read during the first `body`, then cached on appear, never in `init`: the parent rebuilds this
  /// view on every render, and the list must not flash "No profiles" before its first read.
  let loadNames: () -> [String]
  let onPick: (String) -> Void
  /// The user's own profiles: the ones delete mode offers.
  var loadDeletable: () -> [String] = { [] }
  /// Deletes one; false when it could not.
  var onDelete: (String) -> Bool = { _ in false }

  @State private var names: [String]?
  @State private var deletable: [String] = []
  @State private var isDeleting = false
  /// The profile the alert asks about.
  @State private var pendingDelete: String?
  /// Kept while the alert animates out, so its message never blanks.
  @State private var shownDelete: String?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    MenuScreen(
      model: ProfileListModelBuilder.make(
        names: names ?? loadNames(), current: current,
        onPick: { name in
          onPick(name)
          dismiss()
        },
        deletable: deletable, isDeleting: isDeleting,
        onToggleDeleting: { isDeleting.toggle() },
        onDelete: { pendingDelete = $0 }),
      style: .list,
      onBack: { dismiss() },
      modal: pendingDelete.map { name in
        MenuModal(onConfirm: { confirmDelete(name) }, onCancel: { pendingDelete = nil })
      })
      .navigationTitle(L("Load Profile"))
      .onAppear {
        if names == nil { names = loadNames() }
        deletable = loadDeletable()
      }
      .alert(
        L("Delete Profile?"),
        isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
        presenting: pendingDelete ?? shownDelete
      ) { name in
        Button(L("Delete"), role: .destructive) { confirmDelete(name) }
        Button(L("Cancel"), role: .cancel) { pendingDelete = nil }
      } message: { name in
        Text(String(format: L("%@ will be deleted from this device. Players using it keep their buttons."), name))
      }
      .onChange(of: pendingDelete) { _, name in
        if let name { shownDelete = name }
      }
  }

  private func confirmDelete(_ name: String) {
    pendingDelete = nil
    _ = onDelete(name)
    names = loadNames()
    deletable = loadDeletable()
    if ProfileListModelBuilder.deletableNames(names ?? [], deletable: deletable).isEmpty {
      isDeleting = false
    }
  }
}

/// Pure: the profile names (user and bundled, as `TVControllerMappingBridge.profiles(forGCPort:)`
/// lists them, already narrowed to the ones that work on the slot's device) in case-insensitive
/// order, the current one marked. With any of the user's own profiles listed, a last row switches
/// delete mode, in which only those can be picked, and picking one asks to delete it.
enum ProfileListModelBuilder {
  static let deleteModeID = "profiles-delete-mode"

  static func make(
    names: [String], current: String?, onPick: @escaping (String) -> Void,
    deletable: [String] = [], isDeleting: Bool = false,
    onToggleDeleting: @escaping () -> Void = {}, onDelete: @escaping (String) -> Void = { _ in }
  ) -> MenuModel {
    let sorted = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    guard !sorted.isEmpty else {
      // Enabled no-op: tvOS focus needs a row to land on.
      return MenuModel(sections: [
        MenuSection(id: "profiles", items: [MenuItem(id: "no-profiles", title: L("No profiles"), role: .action({}))]),
      ])
    }
    let canDelete = Set(deletableNames(sorted, deletable: deletable))
    let deleting = isDeleting && !canDelete.isEmpty
    var sections = [
      MenuSection(id: "profiles", header: L("Profiles"), items: sorted.map { name in
        if deleting {
          let isUsers = canDelete.contains(name)
          return MenuItem(
            id: "profile-\(name)", title: name, icon: isUsers ? "trash" : "doc.text", tint: isUsers ? .red : nil,
            role: .action { onDelete(name) }, badge: isUsers ? nil : L("Built-In"), isEnabled: isUsers)
        }
        return MenuItem(
          id: "profile-\(name)", title: name, icon: "doc.text",
          role: .action { onPick(name) }, badge: name == current ? L("Current") : nil)
      }),
    ]
    if !canDelete.isEmpty {
      sections.append(MenuSection(id: "profiles-manage", items: [
        deleting
          ? MenuItem(id: deleteModeID, title: L("Done"), icon: "checkmark", role: .action(onToggleDeleting))
          : MenuItem(
            id: deleteModeID, title: L("Delete a Profile…"), subtitle: L("Only profiles you saved can be deleted."),
            icon: "trash", role: .action(onToggleDeleting)),
      ]))
    }
    return MenuModel(sections: sections)
  }

  /// The listed names that are the user's own (the file system ignores case).
  static func deletableNames(_ names: [String], deletable: [String]) -> [String] {
    names.filter { ProfileNaming.exists($0, in: deletable) }
  }
}
