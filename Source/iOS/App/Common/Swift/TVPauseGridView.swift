// Common/Swift/TVPauseGridView.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(tvOS)
import SwiftUI

/// The tvOS pause menu as a 10-foot, console-style screen, ported from iFly's `PauseMenuView+tvOSGrid`: the game
/// hero on the left, large focus-glowing tiles on the right (the session row, then Options), and a help footer that
/// explains the focused tile. The host draws the full-bleed room behind it (`ICubeTVRoomBackground`).
///
/// Which tiles exist and what they do is `PauseMenuModelBuilder.tvLayout`'s model: a headerless primary row, then
/// a headed Options section. Tiles activate through `MenuItem.activateInPlace()`, the same path `MenuScreen` uses,
/// so a cycle steps, a toggle flips and an action runs exactly as on iOS. A long-press opens the item's long-press
/// (an options picker, or an action such as the full shader picker).
struct TVPauseGridView<Hero: View>: View {
  let model: MenuModel
  /// The tile focused last. Read when the grid appears (Back from a pane lands on the tile that opened it) and
  /// written as focus moves.
  @Binding var lastFocusID: String?
  /// Menu at the grid itself.
  let onBack: () -> Void
  @ViewBuilder let hero: () -> Hero

  @FocusState private var focusedID: String?
  /// The help footer keeps describing the last focused tile while focus is in a dialog above the grid.
  @State private var shelfID: String?
  @State private var picker: OptionsPicker?
  /// A long-press also ends in the Button's select; this swallows that one select.
  @State private var suppressActivateFor: String?
  @Environment(\.icubePlatformAccent) private var platformAccent

  private struct OptionsPicker: Identifiable {
    let id: String
    let title: String
    let options: [(String, AnyHashable)]
    let selection: Binding<AnyHashable>
  }

  private static var longPressDuration: Double { 0.5 }
  private typealias Layout = ICubeDesign.TVPause

  private var accent: Color { platformAccent ?? ICubeDesign.color(.accent) }

  private var initialFocusID: String? {
    if let id = lastFocusID, model.focusableIDs.contains(id) { return id }
    return model.focusableIDs.first
  }

  var body: some View {
    ZStack {
      VStack(spacing: Layout.footerGap) {
        HStack(alignment: .center, spacing: Layout.heroGap) {
          hero()
            .frame(width: Layout.heroWidth, alignment: .leading)
          tiles
        }
        .frame(maxHeight: .infinity)
        helpFooter
      }
      .padding(.horizontal, Layout.horizontalMargin)
      .padding(.top, Layout.topMargin)
      .padding(.bottom, Layout.bottomMargin)
      .disabled(picker != nil)

      if let picker {
        ICubeConfirmPanel(
          title: picker.title, message: nil,
          model: MenuModel.optionsPicker(itemID: picker.id, options: picker.options, selection: picker.selection,
                                         onPick: closePicker),
          isTV: true, onBack: closePicker)
      }
    }
    .ignoresSafeArea()
    .defaultFocus($focusedID, initialFocusID)
    .onAppear {
      // `.defaultFocus` applies only while nothing has focus; coming back from a pane, place it explicitly.
      let id = initialFocusID
      DispatchQueue.main.async { if focusedID == nil { focusedID = id } }
    }
    .onChange(of: focusedID) { _, id in
      guard let id else { return }
      shelfID = id
      lastFocusID = id
    }
    .onExitCommand { if picker == nil { onBack() } }
  }

  // MARK: - Tiles

  private var tiles: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
        ForEach(model.sections) { section in
          if let header = section.header {
            ICubeAccentHeader(text: header)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Layout.gridSpacing),
                                     count: PauseTileLayout.tvColumns),
                      spacing: Layout.gridSpacing) {
              ForEach(section.items) { item in tile(item, prominent: false, isLead: false) }
            }
          } else {
            HStack(spacing: Layout.primaryRowSpacing) {
              ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                tile(item, prominent: true, isLead: index == 0)
              }
            }
          }
        }
      }
      .padding(.vertical, ICubeDesign.Spacing.xs.rawValue)
      // Room for the focus scale and glow inside the scroll view's clip...
      .padding(ICubeDesign.Card.glowInset)
    }
    // ...cancelled again, so the clip edge moves outward and the tiles stay put.
    .padding(-ICubeDesign.Card.glowInset)
  }

  private func tile(_ item: MenuItem, prominent: Bool, isLead: Bool) -> some View {
    Button { activate(item) } label: {
      TVPauseTileFace(item: item, prominent: prominent, isLead: isLead)
    }
    .buttonStyle(ICubeCardButtonStyle())
    .disabled(!item.isEnabled)
    .focused($focusedID, equals: item.id)
    .simultaneousGesture(LongPressGesture(minimumDuration: Self.longPressDuration).onEnded { _ in runLongPress(item) })
    .accessibilityIdentifier("pause.tile.\(item.id)")
  }

  // MARK: - Help footer

  private var footerItem: MenuItem? { (focusedID ?? shelfID ?? initialFocusID).flatMap { model.item(id: $0) } }

  private var helpFooter: some View {
    let shape = RoundedRectangle(cornerRadius: Layout.footerCornerRadius, style: .continuous)
    return HStack(alignment: .center, spacing: ICubeDesign.Spacing.l.rawValue) {
      if let item = footerItem {
        Image(systemName: item.icon ?? "info.circle")
          .font(ICubeDesign.symbolFont(.tile))
          .foregroundStyle(item.role.isDestructive ? (item.tint ?? ICubeDesign.color(.destructive)) : accent)
          .frame(width: ICubeDesign.IconBadge.size)
        VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
          Text(item.title)
            .icubeText(.nav)
            .foregroundStyle(ICubeDesign.color(.textSecondary))
            .lineLimit(1)
          Text(item.description ?? " ")
            .icubeText(.body)
            .foregroundStyle(ICubeDesign.color(.textPrimary))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .id(item.id)
        .transition(.opacity)
        if let value = item.currentValueTitle ?? item.badge, !value.isEmpty {
          TVPauseValueChip(text: value, focused: false)
        }
      }
      Spacer(minLength: ICubeDesign.Spacing.l.rawValue)
      Label(L("Resume"), systemImage: "playpause.fill")
        .icubeText(.nav)
        .foregroundStyle(ICubeDesign.color(.textSecondary))
        .labelStyle(.titleAndIcon)
        .fixedSize()
    }
    .padding(.horizontal, ICubeDesign.Spacing.l.rawValue)
    .frame(maxWidth: .infinity, minHeight: Layout.footerHeight, maxHeight: Layout.footerHeight, alignment: .leading)
    .background(shape.fill(ICubeDesign.Card.surface.opacity(Layout.footerFillOpacity)))
    .overlay(shape.strokeBorder(ICubeDesign.color(.accent).opacity(Layout.footerBorderOpacity),
                                lineWidth: ICubeDesign.Line.hairline.rawValue))
    .animation(ICubeDesign.Motion.selection, value: footerItem?.id)
  }

  // MARK: - Actions

  private func activate(_ item: MenuItem) {
    if suppressActivateFor == item.id {
      suppressActivateFor = nil
      return
    }
    item.activateInPlace()
  }

  private func runLongPress(_ item: MenuItem) {
    guard item.isEnabled, let longPress = item.effectiveLongPress else { return }
    suppressActivateFor = item.id
    switch longPress {
    case .action(let run):
      run()
      // A presentation cancels the press, so the Button's select never comes to consume the flag.
      suppressActivateFor = nil
    case .options(let title, let options, let selection):
      picker = OptionsPicker(id: item.id, title: title, options: options, selection: selection)
    }
  }

  private func closePicker() {
    let id = picker?.id
    picker = nil
    suppressActivateFor = nil
    DispatchQueue.main.async { focusedID = id }
  }
}

/// One pause tile, iFly's `TileFace`: glyph over an uppercase title, white on focus. Destructive tiles keep their
/// own tint (Reset orange, Exit red); the lead tile (Resume) is in the platform accent. The current value (SLOT 1,
/// OFF, 2X, NATIVE, CIR) sits in a chip in the top-trailing corner.
private struct TVPauseTileFace: View {
  let item: MenuItem
  let prominent: Bool
  let isLead: Bool
  @Environment(\.icubeCardFocused) private var focused
  @Environment(\.icubePlatformAccent) private var platformAccent

  private static var disabledOpacity: Double { 0.45 }
  private static var titleMinimumScale: CGFloat { 0.85 }

  var body: some View {
    let accent = platformAccent ?? ICubeDesign.color(.accent)
    let foreground: Color = item.role.isDestructive
      ? (item.tint ?? ICubeDesign.color(.destructive))
      : (focused ? .white : (isLead ? accent : ICubeDesign.color(.textPrimary)))
    let height = prominent ? ICubeDesign.TVPause.primaryTileHeight : ICubeDesign.TVPause.tileHeight
    return ZStack(alignment: .topTrailing) {
      VStack(spacing: ICubeDesign.Spacing.s.rawValue) {
        if let icon = item.icon {
          Image(systemName: icon)
            .font(ICubeDesign.symbolFont(prominent ? .tilePrimary : .tile))
        }
        Text(item.title)
          .icubeText(.nav)
          .lineLimit(2)
          .multilineTextAlignment(.center)
          // Two lines and a gentle floor: a 0.7 floor shrank long titles below 10-foot legibility.
          .minimumScaleFactor(Self.titleMinimumScale)
      }
      .foregroundStyle(foreground)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.horizontal, ICubeDesign.Spacing.xs.rawValue)

      if let value = item.currentValueTitle ?? item.badge, !value.isEmpty {
        TVPauseValueChip(text: value, focused: focused)
          .padding(ICubeDesign.Spacing.s.rawValue)
      }
    }
    .frame(height: height)
    .icubeCardSurface()
    .opacity(item.isEnabled ? 1 : Self.disabledOpacity)
  }
}

/// A tile's or the footer's current value, as a `tag` capsule in the platform accent.
private struct TVPauseValueChip: View {
  let text: String
  let focused: Bool
  @Environment(\.icubePlatformAccent) private var platformAccent

  private static var focusedFillOpacity: Double { 0.35 }

  var body: some View {
    let accent = platformAccent ?? ICubeDesign.color(.accent)
    Text(text)
      .icubeText(.tag)
      .lineLimit(1)
      .foregroundStyle(focused ? .white : accent)
      .padding(.horizontal, ICubeDesign.Spacing.xs.rawValue)
      .padding(.vertical, ICubeDesign.Spacing.xxs.rawValue)
      .background(Capsule().fill(accent.opacity(focused ? Self.focusedFillOpacity : ICubeDesign.IconBadge.tintOpacity)))
  }
}
#endif
