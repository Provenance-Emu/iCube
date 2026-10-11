// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

#if os(tvOS)

/// Where the tvOS library content column is looking.
enum TVLibraryRailDestination: Hashable {
  /// Recently played, favorites, and the mixed library.
  case home
  /// Every game, without the favorites shelf.
  case all
  /// One platform's games.
  case platform(LibraryPlatformCategory)
}

/// Collapsible left rail for the tvOS library. Icon-only until a row is focused.
struct TVLibraryRail<ImportMenu: View, ViewMenu: View, SortMenu: View>: View {
  @Binding var destination: TVLibraryRailDestination
  @Binding var searchText: String
  let platforms: [LibraryPlatformCategory]
  let isSelecting: Bool
  let onToggleSelect: () -> Void
  let onSettings: () -> Void
  @ViewBuilder var importMenu: () -> ImportMenu
  @ViewBuilder var viewMenu: () -> ViewMenu
  @ViewBuilder var sortMenu: () -> SortMenu

  @FocusState private var focusedItem: Item?
  @FocusState private var searchFieldFocused: Bool
  @State private var showSearchField = false
  /// Covers the frame where the Search button is replaced by the field and focus is briefly nil.
  @State private var searchActivating = false

  private enum Item: Hashable {
    case search
    case library
    case all
    case platform(LibraryPlatformCategory)
    case select
    case importGames
    case view
    case sort
    case settings
  }

  private var isExpanded: Bool {
    focusedItem != nil || showSearchField
  }

  var body: some View {
    VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xs.rawValue) {
      searchRow
      libraryRow(icon: "house.fill", title: L("My Library"), item: .library, selected: destination == .home) {
        destination = .home
      }
      libraryRow(icon: "square.grid.2x2", title: L("All Games"), item: .all, selected: destination == .all) {
        destination = .all
      }
      ForEach(platforms) { platform in
        libraryRow(
          icon: platform.systemImage,
          title: platform.displayName,
          item: .platform(platform),
          selected: destination == .platform(platform)
        ) {
          destination = .platform(platform)
        }
      }
      Spacer(minLength: ICubeDesign.Spacing.l.rawValue)
      libraryRow(
        icon: isSelecting ? "checkmark.circle.fill" : "checkmark.circle",
        title: isSelecting ? L("Done") : L("Select"),
        item: .select,
        selected: isSelecting,
        action: onToggleSelect
      )
      menuRow(icon: "square.and.arrow.down", title: L("Import"), item: .importGames, menu: importMenu)
      menuRow(icon: "slider.horizontal.3", title: L("View"), item: .view, menu: viewMenu)
      menuRow(icon: "arrow.up.arrow.down", title: L("Sort"), item: .sort, menu: sortMenu)
      libraryRow(icon: "gearshape.fill", title: L("Settings"), item: .settings, selected: false, action: onSettings)
    }
    .padding(.vertical, ICubeDesign.Spacing.l.rawValue)
    .padding(.trailing, ICubeDesign.Spacing.s.rawValue)
    .frame(
      width: isExpanded ? ICubeDesign.Motion.railExpandedWidth : ICubeDesign.Motion.railCollapsedWidth,
      alignment: .leading
    )
    .frame(maxHeight: .infinity, alignment: .top)
    .icubePanel()
    .focusSection()
    .animation(ICubeDesign.Motion.selection, value: isExpanded)
    .onChange(of: focusedItem) { _, item in
      if item == nil, !searchFieldFocused, !searchActivating {
        showSearchField = false
      }
    }
    .onChange(of: searchFieldFocused) { _, focused in
      if focused {
        searchActivating = false
      } else if focusedItem == nil, !searchActivating {
        showSearchField = false
      }
    }
  }

  @ViewBuilder
  private var searchRow: some View {
    if isExpanded, showSearchField {
      HStack(spacing: ICubeDesign.Spacing.s.rawValue) {
        Image(systemName: "magnifyingglass")
          .font(ICubeDesign.symbolFont(.shelf))
          .frame(width: ICubeDesign.Spacing.xl.rawValue)
        TextField(L("Search"), text: $searchText)
          .focused($searchFieldFocused)
          .icubeText(.nav)
          .onSubmit { searchFieldFocused = false }
          .onAppear { searchFieldFocused = true }
      }
      .padding(.horizontal, ICubeDesign.Spacing.s.rawValue)
      .focused($focusedItem, equals: .search)
    } else {
      libraryRow(
        icon: "magnifyingglass",
        title: searchText.isEmpty ? L("Search") : searchText,
        item: .search,
        selected: !searchText.isEmpty
      ) {
        searchActivating = true
        showSearchField = true
      }
    }
  }

  private func libraryRow(
    icon: String,
    title: String,
    item: Item,
    selected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      rowLabel(icon: icon, title: title)
    }
    .buttonStyle(ICubeRailButtonStyle(isSelected: selected))
    .focused($focusedItem, equals: item)
  }

  private func menuRow<MenuContent: View>(
    icon: String,
    title: String,
    item: Item,
    @ViewBuilder menu: () -> MenuContent
  ) -> some View {
    Menu(content: menu) {
      rowLabel(icon: icon, title: title)
    }
    .menuStyle(.button)
    .buttonStyle(ICubeRailButtonStyle())
    .focused($focusedItem, equals: item)
  }

  private func rowLabel(icon: String, title: String) -> some View {
    HStack(spacing: ICubeDesign.Spacing.s.rawValue) {
      Image(systemName: icon)
        .font(ICubeDesign.symbolFont(.shelf))
        .frame(width: ICubeDesign.Spacing.xl.rawValue)
      if isExpanded {
        Text(title)
          .icubeText(.nav)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

#endif
