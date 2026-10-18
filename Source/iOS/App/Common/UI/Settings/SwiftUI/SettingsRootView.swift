// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Settings root. tvOS and iPad (regular width) get the sidebar shell; every iPhone gets a grouped list
/// pushing one leaf at a time. Both are generated from `SettingsRootModelBuilder`.
struct SettingsRootView: View {
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.dismiss) private var dismiss
  /// A leaf to open first (the DSU deep link, the tvOS `-ICubeSettingsPreview` argument).
  let initialLeafID: String?
  /// A row inside `initialLeafID` to bring into view (a pause tile's long-press). Scrolled to and tinted on iOS,
  /// focused on tvOS.
  let initialRowID: String?
  /// Set by a host that presents Settings modally (the library's cover, the pause menu's sheet) for a Close
  /// button. Settings owns its navigation stack: a host must not wrap it in another one or push it onto
  /// one, or Back on a leaf pops Settings too.
  let onClose: (() -> Void)?
  /// The row for the leaf's `MenuScreen` to take, once. Made in `init`: the iPhone stack starts with the leaf on it.
  @State private var rowTarget: SettingsRowTarget?
  @State private var jumpToLeafID: String?
  @State private var jumpToControllersRequested = false
  /// Built once: the entries' closures are stable across body evaluations, and `pushed` compares by id.
  @State private var sections: [SettingsRootSection]
  #if os(iOS)
  @State private var searchText = ""
  @State private var pushed: SettingsLeafEntry?
  /// An iPad form sheet lays the sidebar out first, at a passing regular width, and its leaf takes the row.
  @State private var sidebarShown = false
  @State private var phoneRearmedRow = false
  /// Search exists on iOS only, so tvOS never builds the index.
  @State private var searchIndex: SettingsSearchIndex?
  #endif

  init(initialLeafID: String? = nil, initialRowID: String? = nil, onClose: (() -> Void)? = nil) {
    self.initialLeafID = initialLeafID
    self.initialRowID = initialRowID
    self.onClose = onClose
    _rowTarget = State(initialValue: initialRowID.map { SettingsRowTarget(rowID: $0) })
    let sections = Self.makeSections()
    _sections = State(initialValue: sections)
    #if os(iOS)
    // The iPhone stack starts with the leaf on it rather than pushing it once the sheet is up.
    _pushed = State(initialValue: initialLeafID.flatMap { id in sections.flatMap(\.entries).first { $0.id == id } })
    #endif
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
        SettingsSidebarShell(sections: sections, searchIndex: searchIndex, jumpToLeafID: $jumpToLeafID, onClose: onClose)
          .onAppear { sidebarShown = true }
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
      // Opened on a leaf, this list is first laid out by the pop back to it, and a large title then
      // never settles: the navigation bar and the list re-adjust each other's insets forever and the
      // app hangs. An inline title has no collapse to settle.
      .navigationBarTitleDisplayMode(initialLeafID == nil ? .automatic : .inline)
      .searchable(text: $searchText, prompt: L("Search Settings"))
      .toolbar {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
          if let onClose {
            Button(L("Close"), action: onClose)
          }
          SettingsResetAllButton { Text(L("Reset All")) }
        }
      }
      // The row target is handed on explicitly, so a pushed leaf gets it whichever stack ends up hosting the push.
      .navigationDestination(item: $pushed) { entry in entry.pushedView().environment(\.settingsRowTarget, rowTarget) }
      // DSU-add deep link (dolphinios://dsu/add, legacy dsu://) opens the DSU server list, where the server it just added shows.
      .navigationDestination(isPresented: $jumpToControllersRequested) { DSUSettingsView().padBackNavigation() }
    }
    .onChange(of: jumpToLeafID, initial: true) { _, _ in consumePhoneJump() }
    .onAppear(perform: rearmRowAfterSidebar)
  }

  /// The phone list the iPad sheet settles on gets the row again if that passing sidebar's leaf took it.
  private func rearmRowAfterSidebar() {
    guard sidebarShown, !phoneRearmedRow, let initialRowID, rowTarget?.isPending == false else { return }
    phoneRearmedRow = true
    rowTarget = SettingsRowTarget(rowID: initialRowID)
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
