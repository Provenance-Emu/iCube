// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Where the tvOS library content column is looking. Platform-neutral so the iOS test target covers `stepped`.
enum TVLibraryRailDestination: Hashable {
  /// Recently played, favorites, and the mixed library.
  case home
  /// Every game, without the favorites shelf.
  case all
  /// One platform's games.
  case platform(LibraryPlatformCategory)

  /// L1/R1 on a controller: My Library, All Games, then each platform the rail shows, wrapping around.
  /// A destination the rail no longer shows (its platform's last game was removed) steps from My Library.
  func stepped(by delta: Int, platforms: [LibraryPlatformCategory]) -> TVLibraryRailDestination {
    let order: [TVLibraryRailDestination] = [.home, .all] + platforms.map { .platform($0) }
    let index = order.firstIndex(of: self) ?? 0
    let count = order.count
    return order[((index + delta) % count + count) % count]
  }
}

#if os(tvOS)

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
      libraryRow(icon: .symbol("house.fill"), title: L("My Library"), item: .library, selected: destination == .home) {
        destination = .home
      }
      libraryRow(icon: .symbol("square.grid.2x2"), title: L("All Games"), item: .all, selected: destination == .all) {
        destination = .all
      }
      ForEach(platforms) { platform in
        libraryRow(
          icon: .platform(platform),
          title: platform.displayName,
          item: .platform(platform),
          selected: destination == .platform(platform)
        ) {
          destination = .platform(platform)
        }
      }
      Spacer(minLength: ICubeDesign.Spacing.l.rawValue)
      libraryRow(
        icon: .symbol(isSelecting ? "checkmark.circle.fill" : "checkmark.circle"),
        title: isSelecting ? L("Done") : L("Select"),
        item: .select,
        selected: isSelecting,
        action: onToggleSelect
      )
      menuRow(icon: .symbol("square.and.arrow.down"), title: L("Import"), item: .importGames, menu: importMenu)
      menuRow(icon: .symbol("slider.horizontal.3"), title: L("View"), item: .view, menu: viewMenu)
      menuRow(icon: .symbol("arrow.up.arrow.down"), title: L("Sort"), item: .sort, menu: sortMenu)
      libraryRow(icon: .symbol("gearshape.fill"), title: L("Settings"), item: .settings, selected: false, action: onSettings)
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
        railIcon(.symbol("magnifyingglass"))
        TextField(L("Search"), text: $searchText)
          .focused($searchFieldFocused)
          .icubeText(.nav)
          .multilineTextAlignment(.trailing)
          .onSubmit { searchFieldFocused = false }
          .onAppear { searchFieldFocused = true }
      }
      .padding(.horizontal, ICubeDesign.Spacing.s.rawValue)
      .focused($focusedItem, equals: .search)
    } else {
      libraryRow(
        icon: .symbol("magnifyingglass"),
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
    icon: RailIcon,
    title: String,
    item: Item,
    selected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      rowLabel(icon: icon, title: title, selected: selected)
    }
    .buttonStyle(ICubeRailButtonStyle(isSelected: selected))
    .focused($focusedItem, equals: item)
  }

  private func menuRow<MenuContent: View>(
    icon: RailIcon,
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

  /// Icon in a fixed left column; the label ends on the row's trailing edge.
  private func rowLabel(icon: RailIcon, title: String, selected: Bool = false) -> some View {
    HStack(spacing: ICubeDesign.Spacing.s.rawValue) {
      railIcon(icon)
      if isExpanded {
        Text(title)
          .icubeText(.nav)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .foregroundStyle(selected ? ICubeDesign.color(.accent) : ICubeDesign.color(.textPrimary))
  }

  private func railIcon(_ icon: RailIcon) -> some View {
    Group {
      switch icon {
      case .symbol(let name):
        Image(systemName: name)
          .font(ICubeDesign.symbolFont(.rail))
      case .platform(let platform):
        LibraryConsoleGlyph(platform: platform)
          .frame(width: ICubeDesign.Symbol.rail.rawValue, height: ICubeDesign.Symbol.rail.rawValue)
          .foregroundStyle(ICubeDesign.color(.accent))
      }
    }
    .frame(width: ICubeDesign.Symbol.railColumn, height: ICubeDesign.Symbol.railColumn)
  }
}

/// What a rail row draws in the icon column.
private enum RailIcon {
  case symbol(String)
  case platform(LibraryPlatformCategory)
}

/// Original console silhouettes for the rail. Not manufacturer logos.
private struct LibraryConsoleGlyph: View {
  let platform: LibraryPlatformCategory

  var body: some View {
    switch platform {
    case .gameCube: CubeGlyph().stroke(style: glyphStroke)
    case .wii: RemoteGlyph().fill(style: FillStyle(eoFill: true))
    case .wiiWare: ChannelGlyph().fill(style: FillStyle(eoFill: true))
    case .all: EmptyView()
    }
  }

  /// Edge weight from the hairline token, doubled so a 22pt glyph still reads.
  private var glyphStroke: StrokeStyle {
    StrokeStyle(
      lineWidth: ICubeDesign.Line.hairline.rawValue + ICubeDesign.Line.hairline.rawValue,
      lineCap: .round,
      lineJoin: .round
    )
  }
}

/// Isometric cube: outer shell plus the three edges that meet at the front corner.
private struct CubeGlyph: Shape {
  func path(in rect: CGRect) -> Path {
    let s = min(rect.width, rect.height)
    let origin = CGPoint(x: rect.midX - s / 2, y: rect.midY - s / 2)
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: origin.x + x * s, y: origin.y + y * s)
    }
    var path = Path()
    path.move(to: point(0.50, 0.08))
    path.addLine(to: point(0.92, 0.30))
    path.addLine(to: point(0.92, 0.70))
    path.addLine(to: point(0.50, 0.92))
    path.addLine(to: point(0.08, 0.70))
    path.addLine(to: point(0.08, 0.30))
    path.closeSubpath()
    path.move(to: point(0.50, 0.08))
    path.addLine(to: point(0.50, 0.50))
    path.move(to: point(0.08, 0.30))
    path.addLine(to: point(0.50, 0.50))
    path.addLine(to: point(0.92, 0.30))
    return path
  }
}

/// A remote wand: body with the pointer, cross, and button cut out.
private struct RemoteGlyph: Shape {
  func path(in rect: CGRect) -> Path {
    let s = min(rect.width, rect.height)
    let origin = CGPoint(x: rect.midX - s / 2, y: rect.midY - s / 2)
    func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
      CGRect(x: origin.x + x * s, y: origin.y + y * s, width: w * s, height: h * s)
    }
    var path = Path()
    path.addRoundedRect(in: box(0.32, 0.04, 0.36, 0.92), cornerRadii: equalRadii(s * 0.16))
    path.addEllipse(in: box(0.42, 0.12, 0.16, 0.10))
    path.addRect(box(0.44, 0.32, 0.12, 0.22))
    path.addRect(box(0.36, 0.37, 0.28, 0.12))
    path.addEllipse(in: box(0.40, 0.64, 0.20, 0.14))
    return path
  }
}

/// A channel tile: rounded screen with a smaller picture cut out of it.
private struct ChannelGlyph: Shape {
  func path(in rect: CGRect) -> Path {
    let s = min(rect.width, rect.height)
    let origin = CGPoint(x: rect.midX - s / 2, y: rect.midY - s / 2)
    func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
      CGRect(x: origin.x + x * s, y: origin.y + y * s, width: w * s, height: h * s)
    }
    var path = Path()
    path.addRoundedRect(in: box(0.10, 0.16, 0.80, 0.68), cornerRadii: equalRadii(s * 0.14))
    path.addRoundedRect(in: box(0.24, 0.30, 0.52, 0.40), cornerRadii: equalRadii(s * 0.06))
    return path
  }
}

/// Same radius on every corner. `Path` on this SDK takes `RectangleCornerRadii`, not a `CGFloat`.
private func equalRadii(_ radius: CGFloat) -> RectangleCornerRadii {
  RectangleCornerRadii(
    topLeading: radius,
    bottomLeading: radius,
    bottomTrailing: radius,
    topTrailing: radius
  )
}

#endif
