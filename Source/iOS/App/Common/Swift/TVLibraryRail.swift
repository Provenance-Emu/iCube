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
  /// A right press left focus on a rail row. The library disables its content while the rail holds focus (the
  /// expanded rail lies over the cards, and up or down would otherwise slip into them), so it moves focus into
  /// the content itself.
  var onStuckRight: () -> Void = {}
  /// Whether a rail row (or the search field) holds focus.
  var onFocusChange: (Bool) -> Void = { _ in }

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

  /// How long a right press gets to move focus before the rail treats it as stuck.
  private static var stuckMoveDelay: Double { 0.15 }

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
    .padding(.horizontal, ICubeDesign.Spacing.xs.rawValue)
    .frame(
      width: isExpanded ? ICubeDesign.Motion.railExpandedWidth : ICubeDesign.Motion.railCollapsedWidth,
      alignment: .leading
    )
    .frame(maxHeight: .infinity, alignment: .top)
    .modifier(TVLibraryRailPanel())
    .focusSection()
    .animation(ICubeDesign.Motion.selection, value: isExpanded)
    .onMoveCommand { direction in
      // The open search field counts: tvOS edits it in a full-screen keyboard, so a right press on it is
      // navigation too.
      let item = focusedItem
      let onField = searchFieldFocused
      guard direction == .right, item != nil || onField else { return }
      // Give the focus engine its turn first; only a press that went nowhere is handed on. With the content
      // disabled behind the rail that is every right press.
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.stuckMoveDelay) {
        if (item != nil && focusedItem == item) || (onField && searchFieldFocused) { onStuckRight() }
      }
    }
    .onChange(of: focusedItem) { _, item in
      if item == nil, !searchFieldFocused, !searchActivating {
        showSearchField = false
      }
      onFocusChange(item != nil || searchFieldFocused || searchActivating)
    }
    .onChange(of: searchFieldFocused) { _, focused in
      if focused {
        searchActivating = false
      } else if focusedItem == nil, !searchActivating {
        showSearchField = false
      }
      onFocusChange(focused || focusedItem != nil)
    }
  }

  @ViewBuilder
  private var searchRow: some View {
    if isExpanded, showSearchField {
      HStack(spacing: ICubeDesign.Spacing.s.rawValue) {
        railIcon(.symbol("magnifyingglass"), selected: false)
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
    .buttonStyle(TVLibraryRailButtonStyle(isSelected: selected))
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
    .buttonStyle(TVLibraryRailButtonStyle())
    .focused($focusedItem, equals: item)
  }

  /// Icon in a fixed left column, the label right after it. Selected rows take the accent (a platform row its
  /// platform colour); the rest keep quiet icons beside primary labels.
  private func rowLabel(icon: RailIcon, title: String, selected: Bool = false) -> some View {
    HStack(spacing: ICubeDesign.Spacing.m.rawValue) {
      railIcon(icon, selected: selected)
      if isExpanded {
        Text(title)
          .icubeText(.nav)
          .lineLimit(1)
          .minimumScaleFactor(TVLibraryRailStyle.labelMinimumScale)
          .foregroundStyle(selected ? icon.tint : ICubeDesign.color(.textPrimary))
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func railIcon(_ icon: RailIcon, selected: Bool) -> some View {
    Group {
      switch icon {
      case .symbol(let name):
        Image(systemName: name)
          .font(ICubeDesign.symbolFont(.rail))
      case .platform(let platform):
        LibraryConsoleGlyph(platform: platform)
          .frame(width: ICubeDesign.Symbol.rail.rawValue, height: ICubeDesign.Symbol.rail.rawValue)
      }
    }
    .foregroundStyle(selected ? icon.tint : ICubeDesign.color(.textSecondary))
    .frame(width: ICubeDesign.Symbol.railColumn, height: ICubeDesign.Symbol.railColumn)
  }
}

/// Rail row focus, after iFly's rail: an accent wash and outline on the focused row, a fainter wash on the
/// selected one, and no scale, so a label never pushes past the panel edge. Focus is read in a nested view:
/// a struct-level `@Environment(\.isFocused)` does not update on tvOS.
private struct TVLibraryRailButtonStyle: ButtonStyle {
  var isSelected: Bool = false

  func makeBody(configuration: Configuration) -> some View {
    TVLibraryRailButtonChrome(label: configuration.label, isPressed: configuration.isPressed, isSelected: isSelected)
  }
}

private struct TVLibraryRailButtonChrome<Label: View>: View {
  let label: Label
  let isPressed: Bool
  let isSelected: Bool
  @Environment(\.isFocused) private var isFocused

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue, style: .continuous)
    let accent = ICubeDesign.color(.accent)
    let wash = isFocused ? TVLibraryRailStyle.focusedWash : (isSelected ? TVLibraryRailStyle.selectedWash : 0)
    label
      .padding(.horizontal, ICubeDesign.Spacing.s.rawValue)
      .padding(.vertical, ICubeDesign.Spacing.s.rawValue)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(shape.fill(accent.opacity(wash)))
      .overlay(shape.strokeBorder(accent.opacity(isFocused ? TVLibraryRailStyle.outlineOpacity : 0),
                                  lineWidth: TVLibraryRailStyle.outlineWidth))
      .scaleEffect(isPressed ? TVLibraryRailStyle.pressedScale : 1)
      .animation(ICubeDesign.Motion.selection, value: isFocused)
      .focusEffectDisabled()
  }
}

/// The rail's glass, after iFly's glossy panel: the material, a top sheen, a hairline and a soft drop shadow.
private struct TVLibraryRailPanel: ViewModifier {
  private static let sheenOpacity: Double = 0.18
  private static let shadowOpacity: Double = 0.35
  private static let shadowRadius: CGFloat = 18
  private static let shadowDrop: CGFloat = 8

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous)
    content
      .background(.ultraThinMaterial, in: shape)
      .overlay(
        shape
          .fill(LinearGradient(colors: [.white.opacity(Self.sheenOpacity), .clear], startPoint: .top, endPoint: .center))
          .allowsHitTesting(false)
      )
      .overlay(shape.stroke(ICubeDesign.color(.hairline), lineWidth: ICubeDesign.Line.hairline.rawValue))
      .shadow(color: .black.opacity(Self.shadowOpacity), radius: Self.shadowRadius, y: Self.shadowDrop)
  }
}

/// The library scroll area's only edge: opaque in the middle, fading to clear over `leading` on the leading
/// side and `depth` on the others. Used as a mask, so cards and their focus glow ease out under the rail and the
/// screen edges.
struct TVLibraryEdgeFade: View {
  let leading: CGFloat
  let depth: CGFloat

  var body: some View {
    HStack(spacing: 0) {
      LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: leading)
      Color.black
      LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: depth)
    }
    .mask {
      VStack(spacing: 0) {
        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: depth)
        Color.black
        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: depth)
      }
    }
    .allowsHitTesting(false)
  }
}

/// Fast-scroll letter index beside a title-sorted tvOS grid, after Provenance's TV scroll index rail. Its own
/// focus section, so a right press from any grid row reaches it. Moving through the letters skims the grid;
/// Select moves focus to that letter's first game. The letter of the focused game stays marked, and the letter
/// under focus shows large beside the index as the jump hint.
struct TVLibraryScrollIndex: View {
  let buckets: [LibraryIndexBucket]
  /// File path of the focused game; the index marks its letter.
  @Binding var focusedPath: String?
  /// The index letter for a game's file path.
  let label: (String) -> String?
  let onFocusBucket: (LibraryIndexBucket) -> Void
  let onSelectBucket: (LibraryIndexBucket) -> Void

  @FocusState private var focused: String?

  static let width: CGFloat = ICubeDesign.Symbol.railColumn + ICubeDesign.Spacing.s.rawValue * 2
  /// Height of one letter when the column has room; a long index shares the column instead.
  private static let rowHeight: CGFloat = ICubeDesign.Spacing.xl.rawValue
  private static let hintSize: CGFloat = ICubeDesign.Spacing.xxl.rawValue + ICubeDesign.Spacing.l.rawValue

  var body: some View {
    let currentLabel = focusedPath.flatMap(label)
    VStack(spacing: 0) {
      ForEach(buckets) { bucket in
        Button { onSelectBucket(bucket) } label: {
          Text(bucket.label)
            .icubeText(.tag)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(TVLibraryIndexButtonStyle(isCurrent: bucket.label == currentLabel))
        .focused($focused, equals: bucket.label)
        .accessibilityIdentifier("library-index-\(bucket.label)")
      }
    }
    .padding(.vertical, ICubeDesign.Spacing.xs.rawValue)
    .frame(width: Self.width)
    .frame(maxHeight: CGFloat(buckets.count) * Self.rowHeight)
    .modifier(TVLibraryRailPanel())
    .overlay(alignment: .leading) { hint }
    .animation(ICubeDesign.Motion.selection, value: focused)
    .onChange(of: focused) { _, label in
      guard let label, let bucket = buckets.first(where: { $0.label == label }) else { return }
      onFocusBucket(bucket)
    }
  }

  /// The letter under focus, large, to the left of the index.
  @ViewBuilder
  private var hint: some View {
    if let focused {
      Text(focused)
        .icubeText(.title)
        .foregroundStyle(ICubeDesign.titleGradient)
        .frame(width: Self.hintSize, height: Self.hintSize)
        .modifier(TVLibraryRailPanel())
        .offset(x: -(Self.hintSize + ICubeDesign.Spacing.m.rawValue))
        .transition(.opacity)
        .allowsHitTesting(false)
    }
  }
}

/// One index letter: quiet at rest, accent-washed where the grid is, filled and outlined under focus.
private struct TVLibraryIndexButtonStyle: ButtonStyle {
  let isCurrent: Bool

  func makeBody(configuration: Configuration) -> some View {
    TVLibraryIndexButtonChrome(label: configuration.label, isCurrent: isCurrent)
  }
}

private struct TVLibraryIndexButtonChrome<Label: View>: View {
  let label: Label
  let isCurrent: Bool
  @Environment(\.isFocused) private var isFocused

  var body: some View {
    let accent = ICubeDesign.color(.accent)
    let wash = isFocused ? TVLibraryRailStyle.indexFocusedWash : (isCurrent ? TVLibraryRailStyle.indexCurrentWash : 0)
    label
      .foregroundStyle(isFocused ? ICubeDesign.color(.textPrimary)
                       : (isCurrent ? accent : ICubeDesign.color(.textSecondary)))
      .background {
        Capsule()
          .fill(accent.opacity(wash))
          .overlay(Capsule().strokeBorder(accent.opacity(isFocused ? 1 : 0), lineWidth: TVLibraryRailStyle.outlineWidth))
          .padding(.horizontal, ICubeDesign.Spacing.xs.rawValue)
      }
      .scaleEffect(isFocused ? ICubeDesign.Motion.tileFocusScale : 1)
      .animation(ICubeDesign.Motion.focusSpring, value: isFocused)
      .focusEffectDisabled()
  }
}

/// Rail and index constants. Generic views cannot hold static stored properties, so they live here.
private enum TVLibraryRailStyle {
  /// A long platform or search label shrinks this far before it truncates.
  static let labelMinimumScale: CGFloat = 0.8
  static let focusedWash: Double = 0.22
  static let selectedWash: Double = 0.10
  static let outlineOpacity: Double = 0.9
  /// iFly's 2 pt focus outline: lighter than the 4 pt focus ring, which crowds a rail row's label.
  static let outlineWidth: CGFloat = ICubeDesign.Line.hairline.rawValue * 2
  static let pressedScale: CGFloat = 0.97
  static let indexFocusedWash: Double = 0.35
  static let indexCurrentWash: Double = 0.12
}

/// What a rail row draws in the icon column.
private enum RailIcon {
  case symbol(String)
  case platform(LibraryPlatformCategory)

  /// The selected row's colour: the platform's own for a platform row, the app accent otherwise.
  var tint: Color {
    switch self {
    case .symbol: ICubeDesign.color(.accent)
    case .platform(let platform): ICubeDesign.platformAccent(platform)
    }
  }
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
