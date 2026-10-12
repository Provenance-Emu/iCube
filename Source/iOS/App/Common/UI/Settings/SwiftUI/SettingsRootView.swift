// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Settings root. tvOS and iPad (regular width) get the sidebar shell; every iPhone gets a grouped list
/// pushing one leaf at a time. Both are generated from `SettingsRootModelBuilder`.
struct SettingsRootView: View {
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.dismiss) private var dismiss
  /// A leaf to open first (the DSU deep link, the tvOS `-ICubeSettingsPreview` argument).
  var initialLeafID: String? = nil
  @State private var jumpToLeafID: String?
  @State private var jumpToControllersRequested = false
  /// Built once: the entries' closures are stable across body evaluations, and `pushed` compares by id.
  @State private var sections = SettingsRootView.makeSections()
  #if os(iOS)
  @State private var searchText = ""
  @State private var pushed: SettingsLeafEntry?
  /// Search exists on iOS only, so tvOS never builds the index.
  @State private var searchIndex: SettingsSearchIndex?
  #endif

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
    return SettingsRootModelBuilder.sections(isIOS: isIOS, achievements: achievements)
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
      .navigationDestination(item: $pushed) { entry in entry.pushedView() }
      // DSU-add deep link (dolphinios://dsu/add, legacy dsu://) opens the DSU server list, where the server it just added shows.
      .navigationDestination(isPresented: $jumpToControllersRequested) { DSUSettingsView().padBackNavigation() }
    }
  }
  #endif
}

extension Notification.Name {
  /// Posted by the URL router for the DSU deep link; Settings jumps to Controllers (the DSU server list on iPhone).
  static let dolSettingsSelectControllers = Notification.Name("DOLSettingsSelectControllers")
}
