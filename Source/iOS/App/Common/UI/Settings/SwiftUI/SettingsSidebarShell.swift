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
  @Binding var jumpToLeafID: String?

  @State private var selectedID: String?
  @FocusState private var sidebarFocus: String?
  #if !os(tvOS)
  @Environment(\.icube) private var theme
  #endif
  #if os(tvOS)
  @State private var openedAt = Date()
  @Environment(\.dismiss) private var dismiss
  #else
  @State private var searchText = ""
  #endif

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
      #if os(tvOS)
      Rectangle().fill(ICubeDesign.color(.hairline)).frame(width: ICubeDesign.Line.hairline.rawValue)
      #else
      Divider()
      #endif
      NavigationStack {
        if let selected {
          selected.makeView().id(selected.id)
            // Only the pane's root leaf: a sub-leaf pushed from it is a different view, so Menu pops it natively.
            #if os(tvOS)
            .onExitCommand(perform: backToSidebar)
            #endif
        } else {
          #if os(tvOS)
          Text(L("Choose a page"))
            .icubeText(.nav)
            .foregroundStyle(ICubeDesign.color(.textSecondary))
          #else
          Text(L("Choose a page")).foregroundStyle(.secondary)
          #endif
        }
      }
      #if os(tvOS)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background { ICubeRoom(style: .gradient) }
      #endif
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
      consumeJump()
    }
    .onChange(of: jumpToLeafID) { _, _ in consumeJump() }
  }

  /// A deep link (DSU → "controllers") or a debug preview lands on one leaf.
  private func consumeJump() {
    guard let id = jumpToLeafID, entries.contains(where: { $0.id == id }) else { jumpToLeafID = nil; return }
    selectedID = id
    sidebarFocus = id
    jumpToLeafID = nil
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
    #if os(tvOS)
    tvSidebarList
    #else
    padSidebarList
    #endif
  }

  #if os(tvOS)
  /// Token sidebar: accent section headers, nav labels, selected fill, focus ring. Not the stock list.
  private var tvSidebarList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xs.rawValue) {
        ForEach(sections) { section in
          HStack(spacing: ICubeDesign.Spacing.xs.rawValue) {
            Capsule()
              .fill(ICubeDesign.color(.accent))
              .frame(width: ICubeDesign.Line.focus.rawValue, height: ICubeDesign.Spacing.l.rawValue)
            Text(section.header)
              .icubeText(.section)
              .foregroundStyle(ICubeDesign.color(.textPrimary))
          }
          .padding(.top, ICubeDesign.Spacing.m.rawValue)
          ForEach(section.entries) { entry in
            let isSelected = selectedID == entry.id
            Button { selectedID = entry.id } label: {
              HStack(spacing: ICubeDesign.Spacing.s.rawValue) {
                Image(systemName: entry.icon)
                  .font(ICubeDesign.symbolFont(.rail))
                  .frame(width: ICubeDesign.Symbol.railColumn)
                Text(entry.title)
                  .icubeText(.nav)
                  .lineLimit(1)
                Spacer(minLength: 0)
              }
              .foregroundStyle(isSelected ? ICubeDesign.color(.accent) : ICubeDesign.color(.textPrimary))
            }
            .buttonStyle(ICubeRowButtonStyle(isSelected: isSelected))
            .focused($sidebarFocus, equals: entry.id)
          }
        }
      }
      .padding(ICubeDesign.Spacing.l.rawValue)
    }
    .icubePanel()
  }
  #endif

  #if !os(tvOS)
  /// iPad touch sidebar. Unchanged from the stock row treatment.
  private var padSidebarList: some View {
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
                  .fill(selectedID == entry.id ? theme.tileAccent.opacity(Layout.selectedOpacity) : .clear))
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
  #endif

  private var sidebarWidth: CGFloat {
    #if os(tvOS)
    Layout.sidebarWidthTV
    #else
    Layout.sidebarWidthPad
    #endif
  }
}
