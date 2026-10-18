// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Settings root. tvOS and iPad (regular width) get the sidebar shell; every iPhone gets a grouped list
/// pushing one leaf at a time. Both are generated from `SettingsRootModelBuilder`.
struct SettingsRootView: View {
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.dismiss) private var dismiss
  /// A leaf to open first (the DSU deep link, the tvOS `-ICubeSettingsPreview` argument).
  var initialLeafID: String?
  /// A row inside `initialLeafID` to bring into view (a pause tile's long-press). Scrolled to and tinted on iOS,
  /// focused on tvOS.
  var initialRowID: String?
  /// The row for the leaf's `MenuScreen` to take, once. Made here, not on appear: on iPhone the list pushes the leaf
  /// before this view's own `onAppear` runs.
  @State private var rowTarget: SettingsRowTarget?
  @State private var jumpToLeafID: String?
  @State private var jumpToControllersRequested = false
  /// Built once: the entries' closures are stable across body evaluations, and `pushed` compares by id.
  @State private var sections = SettingsRootView.makeSections()
  #if os(iOS)
  @State private var searchText = ""
  @State private var pushed: SettingsLeafEntry?
  /// The phone list pushed `initialLeafID` on its first appearance (`pushInitialLeafOnce`).
  @State private var phonePushedInitialLeaf = false
  /// Search exists on iOS only, so tvOS never builds the index.
  @State private var searchIndex: SettingsSearchIndex?
  #endif

  init(initialLeafID: String? = nil, initialRowID: String? = nil) {
    self.initialLeafID = initialLeafID
    self.initialRowID = initialRowID
    _rowTarget = State(initialValue: initialRowID.map { SettingsRowTarget(rowID: $0) })
  }

  private static func makeSections() -> [SettingsRootSection] {
    #if os(iOS)
    let isIOS = true
    #else
    let isIOS = false
    #endif
    #if USE_RETRO_ACHIEVEMENTS
    let achievements = true
    #else
    let achievements = false
    #endif
    return SettingsRootModelBuilder.sections(isIOS: isIOS, achievements: achievements, debugLeaf: SettingsRootModelBuilder.storeDebugLeaf)
  }

  /// tvOS always; iPad only at regular width. Not the size class alone: it is also `.regular` on a Max iPhone in landscape,
  /// which would drop the search, the toolbar Reset All and the deep link.
  #if os(iOS)
  private var usesSidebar: Bool {
    UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular
  }
  #endif

  var body: some View {
    Group {
      #if os(tvOS)
      SettingsSidebarShell(sections: sections, searchIndex: nil, jumpToLeafID: $jumpToLeafID)
      #else
      if usesSidebar {
        SettingsSidebarShell(sections: sections, searchIndex: searchIndex, jumpToLeafID: $jumpToLeafID)
      } else {
        phoneList
      }
      #endif
    }
    #if os(tvOS)
    .background { ICubeRoom(style: .gradient) }
    #endif
    .environment(\.settingsRowTarget, rowTarget)
    .onAppear { if jumpToLeafID == nil { jumpToLeafID = initialLeafID } }
    .onReceive(NotificationCenter.default.publisher(for: .dolSettingsSelectControllers)) { _ in
      jumpToLeafID = "controllers"
      jumpToControllersRequested = true
    }
    #if os(iOS)
    .task { if searchIndex == nil { searchIndex = SettingsSearchIndex(sections: sections) } }   // once per appearance
    #endif
  }

  #if os(iOS)
  private var phoneList: some View {
    NavigationStack {
      Group {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
          MenuScreen(model: SettingsRootModelBuilder.model(sections: sections, onSelect: { pushed = $0 }), style: .list,
                     onBack: { dismiss() })
        } else {
          SettingsSearchResults(hits: searchIndex?.hits(query: searchText) ?? [], entries: sections.flatMap(\.entries)) { pushed = $0 }
        }
      }
      .navigationTitle(L("Settings"))
      .searchable(text: $searchText, prompt: L("Search Settings"))
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          SettingsResetAllButton { Text(L("Reset All")) }
        }
      }
      // The row target is handed on explicitly: inside the pause menu's sheet this stack nests in the sheet's own, and a
      // push lands on the outer stack, outside this view's environment.
      .navigationDestination(item: $pushed) { entry in entry.pushedView().environment(\.settingsRowTarget, rowTarget) }
      // DSU-add deep link (dolphinios://dsu/add, legacy dsu://) opens the DSU server list, where the server it just added shows.
      .navigationDestination(isPresented: $jumpToControllersRequested) { DSUSettingsView().padBackNavigation() }
    }
    .onChange(of: jumpToLeafID, initial: true) { _, _ in consumePhoneJump() }
    .onAppear(perform: pushInitialLeafOnce)
  }

  /// The phone list opens `initialLeafID` itself the first time it appears. An iPad form sheet can lay the sidebar out
  /// first, at a passing regular width: the sidebar then took the jump (and the row), and the list it settled on stayed
  /// on the root. The row target is armed again for the pushed leaf.
  private func pushInitialLeafOnce() {
    guard !phonePushedInitialLeaf, let initialLeafID else { return }
    phonePushedInitialLeaf = true
    guard pushed?.id != initialLeafID, let entry = sections.flatMap(\.entries).first(where: { $0.id == initialLeafID }) else { return }
    if let initialRowID, rowTarget?.isPending == false { rowTarget = SettingsRowTarget(rowID: initialRowID) }
    pushed = entry
  }

  /// `initialLeafID` (the pause menu's tiles and long-presses) pushes that leaf. The DSU link pushes the
  /// DSU list itself, so its "controllers" id is dropped here rather than pushed on top of it.
  private func consumePhoneJump() {
    guard let id = jumpToLeafID else { return }
    jumpToLeafID = nil
    guard !jumpToControllersRequested else { return }
    pushed = sections.flatMap(\.entries).first { $0.id == id }
  }
  #endif
}

extension Notification.Name {
  /// Posted by the URL router for the DSU deep link; Settings jumps to Controllers (the DSU server list on iPhone).
  static let dolSettingsSelectControllers = Notification.Name("DOLSettingsSelectControllers")
}
