// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// tvOS and iPad (regular width): a sidebar of leaf pages grouped under section headers, and the selected
/// leaf in the pane. The sidebar is its own focus section; right enters the pane. Back (Menu / B) from a
/// leaf returns to the sidebar; Menu at the sidebar leaves Settings (through `BackCoalescer`, so the press
/// that opened Settings cannot close it again).
struct SettingsSidebarShell: View {
  let sections: [SettingsRootSection]
  let searchIndex: SettingsSearchIndex?
  @Binding var jumpToControllers: Bool

  @State private var selectedID: String?
  @FocusState private var sidebarFocus: String?
  @Environment(\.menuTheme) private var theme
  #if os(tvOS)
  @State private var openedAt = Date()
  @Environment(\.dismiss) private var dismiss
  #else
  @State private var searchText = ""
  #endif

  private static let controllersID = "controllers"

  private enum Layout {
    static let sidebarWidthTV: CGFloat = 320
    static let sidebarWidthPad: CGFloat = 240
    static let iconWidth: CGFloat = 28
    static let rowRadius: CGFloat = 10
    static let selectedOpacity = 0.25
    static let headerTopPadding: CGFloat = 18
    static let rowStackSpacing: CGFloat = 6
    static let rowContentSpacing: CGFloat = 12
    static let rowHorizontalPadding: CGFloat = 12
    static let rowVerticalPadding: CGFloat = 10
    static let listHorizontalPadding: CGFloat = 20
    static let listVerticalPadding: CGFloat = 24
  }

  private var entries: [SettingsLeafEntry] { sections.flatMap(\.entries) }
  private var selected: SettingsLeafEntry? { entries.first { $0.id == selectedID } }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
        .frame(width: sidebarWidth)
        #if os(tvOS)
        .focusSection()
        .onExitCommand(perform: leaveSettings)
        #endif
      Divider()
      NavigationStack {
        if let selected {
          selected.makeView().id(selected.id)
            // Only the pane's root leaf: a sub-leaf pushed from it is a different view, so Menu pops it natively.
            #if os(tvOS)
            .onExitCommand(perform: backToSidebar)
            #endif
        } else {
          Text(L("Choose a page")).foregroundStyle(.secondary)
        }
      }
      // A leaf in the pane is the root of this stack: its Back must return to the sidebar, not dismiss Settings.
      .environment(\.settingsPaneBack, { sidebarFocus = selectedID })
      #if os(tvOS)
      .focusSection()
      #endif
    }
    .defaultFocus($sidebarFocus, selectedID ?? sections.first?.entries.first?.id)
    .onAppear {
      #if os(tvOS)
      openedAt = Date()
      #endif
      if selectedID == nil { selectedID = sections.first?.entries.first?.id }
      if jumpToControllers { selectControllers() }
    }
    .onChange(of: jumpToControllers) { _, requested in
      if requested { selectControllers() }
    }
  }

  /// The DSU deep link lands on the Controllers leaf.
  private func selectControllers() {
    selectedID = Self.controllersID
    sidebarFocus = Self.controllersID
    jumpToControllers = false
  }

  #if os(tvOS)
  /// Menu with focus in the sidebar: leave Settings, unless it is the release of the press that opened it.
  private func leaveSettings() {
    guard BackCoalescer.shouldHonor(openedAt: openedAt, now: Date()) else { return }
    dismiss()
  }

  /// Menu with focus in a hand-built leaf (a migrated one routes Back through `settingsPaneBack`).
  private func backToSidebar() {
    sidebarFocus = selectedID
  }
  #endif

  @ViewBuilder
  private var sidebar: some View {
    #if os(iOS)
    NavigationStack {
      Group {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
          sidebarList
        } else {
          SettingsSearchResults(hits: searchIndex?.hits(query: searchText) ?? [], entries: entries) { entry in
            selectedID = entry.id
            searchText = ""
          }
        }
      }
      .navigationTitle(L("Settings"))
      .searchable(text: $searchText, prompt: L("Search Settings"))
    }
    #else
    sidebarList
    #endif
  }

  private var sidebarList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Layout.rowStackSpacing) {
        ForEach(sections) { section in
          Text(section.header)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, Layout.headerTopPadding)
            .padding(.horizontal, Layout.rowHorizontalPadding)
          ForEach(section.entries) { entry in
            Button { selectedID = entry.id } label: {
              HStack(spacing: Layout.rowContentSpacing) {
                Image(systemName: entry.icon).frame(width: Layout.iconWidth)
                Text(entry.title).lineLimit(1)
                Spacer(minLength: 0)
              }
              .padding(.horizontal, Layout.rowHorizontalPadding)
              .padding(.vertical, Layout.rowVerticalPadding)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(
                RoundedRectangle(cornerRadius: Layout.rowRadius, style: .continuous)
                  .fill(selectedID == entry.id ? theme.accent.opacity(Layout.selectedOpacity) : .clear))
            }
            .buttonStyle(FocusButtonStyle())
            .focused($sidebarFocus, equals: entry.id)
          }
        }
      }
      .padding(.horizontal, Layout.listHorizontalPadding)
      .padding(.vertical, Layout.listVerticalPadding)
    }
  }

  private var sidebarWidth: CGFloat {
    #if os(tvOS)
    Layout.sidebarWidthTV
    #else
    Layout.sidebarWidthPad
    #endif
  }
}
