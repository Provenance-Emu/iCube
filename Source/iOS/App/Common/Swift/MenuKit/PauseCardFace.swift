// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The pause tile, iFly's `TileFace` on every platform: a glyph over an uppercase title, white while focused or
/// pressed. Destructive tiles keep their own tint (Reset orange, Exit red); the lead tile (Resume) is in the platform
/// accent. The current value (SLOT 1, OFF, 2X, NATIVE, CIR) sits in a chip in the top-trailing corner. Used inside
/// `ICubeCardButtonStyle`, which publishes focus as `\.icubeCardFocused`; the face draws its own card surface.
struct PauseCardFace: View {
  let item: MenuItem
  let prominent: Bool
  let isLead: Bool
  /// iPhone landscape: shorter cards, the glyph beside the title.
  var compact = false
  @Environment(\.icubeCardFocused) private var focused
  @Environment(\.icubePlatformAccent) private var platformAccent

  private typealias Metrics = ICubeDesign.PauseCard

  var body: some View {
    let accent = platformAccent ?? ICubeDesign.color(.accent)
    let foreground: Color = item.role.isDestructive
      ? (item.tint ?? ICubeDesign.color(.destructive))
      : (focused ? .white : (isLead ? accent : ICubeDesign.color(.textPrimary)))
    return ZStack(alignment: .topTrailing) {
      Group {
        if compact {
          HStack(spacing: ICubeDesign.Spacing.xs.rawValue) {
            glyph
            title.multilineTextAlignment(.leading)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, ICubeDesign.Spacing.s.rawValue)
          // Clear of the value chip, which sits in the top-trailing corner.
          .padding(.top, value == nil ? 0 : Metrics.compactChipClearance)
        } else {
          VStack(spacing: Metrics.glyphTitleSpacing) {
            glyph
            title.multilineTextAlignment(.center)
          }
          .padding(.horizontal, ICubeDesign.Spacing.xs.rawValue)
        }
      }
      .foregroundStyle(foreground)
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      if let value {
        PauseValueChip(text: value, focused: focused)
          .padding(Metrics.chipInset)
      }
    }
    .frame(height: Metrics.height(prominent: prominent, compact: compact))
    .icubeCardSurface(cornerRadius: Metrics.cornerRadius)
    .opacity(item.isEnabled ? 1 : Metrics.disabledOpacity)
    .accessibilityElement(children: .combine)
    .accessibilityValue(value ?? "")
  }

  private var value: String? {
    guard let value = item.currentValueTitle ?? item.badge, !value.isEmpty else { return nil }
    return value
  }

  @ViewBuilder private var glyph: some View {
    if let icon = item.icon {
      Image(systemName: icon)
        .font(.system(size: Metrics.glyphSize(prominent: prominent, compact: compact), weight: .medium))
    }
  }

  private var title: some View {
    // The size first: the font closest to the text wins, and the role still sets case and tracking.
    Text(item.title)
      .font(Metrics.titleFont)
      .icubeText(.nav)
      .lineLimit(2)
      // Two lines and a gentle floor: a lower floor shrank long titles below legibility.
      .minimumScaleFactor(Metrics.titleMinimumScale)
  }
}

/// A tile's or the help shelf's current value, as a `tag` capsule in the platform accent.
struct PauseValueChip: View {
  let text: String
  let focused: Bool
  @Environment(\.icubePlatformAccent) private var platformAccent

  var body: some View {
    let accent = platformAccent ?? ICubeDesign.color(.accent)
    Text(text)
      .icubeText(.tag)
      .lineLimit(1)
      .foregroundStyle(focused ? .white : accent)
      .padding(.horizontal, ICubeDesign.Spacing.xs.rawValue)
      .padding(.vertical, ICubeDesign.Spacing.xxs.rawValue)
      .background(Capsule().fill(accent.opacity(focused ? ICubeDesign.PauseCard.focusedChipOpacity : ICubeDesign.IconBadge.tintOpacity)))
  }
}

/// The bar under the pause tiles: the focused (or last touched) tile's glyph, name and description, and its value.
/// With nothing to describe it shows `placeholder`. `trailing` holds a remote hint on tvOS.
struct PauseHelpShelf<Trailing: View>: View {
  let item: MenuItem?
  var placeholder: String = ""
  @ViewBuilder var trailing: () -> Trailing
  @Environment(\.icubePlatformAccent) private var platformAccent

  private typealias Metrics = ICubeDesign.PauseCard

  var body: some View {
    let accent = platformAccent ?? ICubeDesign.color(.accent)
    let shape = RoundedRectangle(cornerRadius: Metrics.shelfCornerRadius, style: .continuous)
    return HStack(alignment: .center, spacing: Metrics.shelfSpacing) {
      Image(systemName: item?.icon ?? "info.circle")
        .font(.system(size: Metrics.shelfGlyph, weight: .medium))
        .foregroundStyle(item.map { $0.role.isDestructive ? ($0.tint ?? ICubeDesign.color(.destructive)) : accent } ?? accent)
        .frame(width: Metrics.shelfGlyphColumn)
      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
        if let item {
          Text(item.title)
            .font(Metrics.titleFont)
            .icubeText(.nav)
            .foregroundStyle(ICubeDesign.color(.textSecondary))
            .lineLimit(1)
        }
        Text(item?.description ?? placeholder)
          .font(Metrics.shelfBodyFont)
          .icubeText(.body)
          .foregroundStyle(ICubeDesign.color(.textPrimary))
          .lineLimit(2)
          .minimumScaleFactor(Metrics.shelfMinimumScale)
          .fixedSize(horizontal: false, vertical: true)
      }
      .id(item?.id)
      .transition(.opacity)
      Spacer(minLength: ICubeDesign.Spacing.s.rawValue)
      if let value = item.flatMap({ $0.currentValueTitle ?? $0.badge }), !value.isEmpty {
        PauseValueChip(text: value, focused: false)
      }
      trailing()
    }
    .padding(.horizontal, Metrics.shelfHorizontalPadding)
    .frame(maxWidth: .infinity, minHeight: Metrics.shelfHeight, maxHeight: Metrics.shelfHeight, alignment: .leading)
    .background(shape.fill(ICubeDesign.Card.surface.opacity(Metrics.shelfFillOpacity)))
    .overlay(shape.strokeBorder(ICubeDesign.color(.accent).opacity(Metrics.shelfBorderOpacity),
                                lineWidth: ICubeDesign.Line.hairline.rawValue))
    .animation(ICubeDesign.Motion.selection, value: item?.id)
  }
}

extension PauseHelpShelf where Trailing == EmptyView {
  init(item: MenuItem?, placeholder: String = "") {
    self.init(item: item, placeholder: placeholder) { EmptyView() }
  }
}

extension ICubeDesign {
  /// Pause card and help-shelf geometry. tvOS keeps iFly's 1080p numbers (`TVPause`); iPhone and iPad scale them
  /// down for touch, with a shorter compact card for iPhone landscape.
  enum PauseCard {
    #if os(tvOS)
    static let cornerRadius: CGFloat = Card.cornerRadius
    static let glyphTitleSpacing: CGFloat = Spacing.s.rawValue
    static let chipInset: CGFloat = Spacing.s.rawValue
    static let titleFont: Font = ICubeDesign.standard.font(.nav)
    static let shelfBodyFont: Font = ICubeDesign.standard.font(.body)
    static let shelfHeight: CGFloat = TVPause.footerHeight
    static let shelfCornerRadius: CGFloat = TVPause.footerCornerRadius
    static let shelfGlyph: CGFloat = Symbol.tile.rawValue
    static let shelfGlyphColumn: CGFloat = IconBadge.size
    static let shelfSpacing: CGFloat = Spacing.l.rawValue
    static let shelfHorizontalPadding: CGFloat = Spacing.l.rawValue
    #else
    static let cornerRadius: CGFloat = 16
    static let glyphTitleSpacing: CGFloat = Spacing.xs.rawValue
    static let chipInset: CGFloat = 6
    /// 13 pt display face: "PERFORMANCE HUD" fits a third of an iPhone in two lines.
    static let titleFont: Font = ICubeDesign.displayFont(size: 13, relativeTo: .footnote)
    static let shelfBodyFont: Font = .subheadline
    static let shelfHeight: CGFloat = 64
    static let shelfCornerRadius: CGFloat = 14
    static let shelfGlyph: CGFloat = 20
    static let shelfGlyphColumn: CGFloat = 28
    static let shelfSpacing: CGFloat = Spacing.s.rawValue
    static let shelfHorizontalPadding: CGFloat = Spacing.m.rawValue
    #endif
    /// iOS card grid (`MenuStyle.cards`); tvOS spaces its grid with `TVPause`.
    static let gridSpacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 16
    /// Room inside the cards' scroll view for the focus scale and glow. Small on a phone: the band also lets cards
    /// scroll under the hero above.
    static let scrollInset: CGFloat = 14
    static let compactChipClearance: CGFloat = 10
    static let titleMinimumScale: CGFloat = 0.85
    static let shelfMinimumScale: CGFloat = 0.8
    static let disabledOpacity: Double = 0.45
    static let focusedChipOpacity: Double = 0.35
    static let shelfFillOpacity: Double = TVPause.footerFillOpacity
    static let shelfBorderOpacity: Double = TVPause.footerBorderOpacity

    static func height(prominent: Bool, compact: Bool) -> CGFloat {
      #if os(tvOS)
      return prominent ? TVPause.primaryTileHeight : TVPause.tileHeight
      #else
      if compact { return prominent ? 60 : 54 }
      return prominent ? 96 : 84
      #endif
    }

    static func glyphSize(prominent: Bool, compact: Bool) -> CGFloat {
      #if os(tvOS)
      return prominent ? Symbol.tilePrimary.rawValue : Symbol.tile.rawValue
      #else
      if compact { return 17 }
      return prominent ? 26 : 22
      #endif
    }
  }

  /// The display face at an explicit size (the type roles' sizes are fixed), following Dynamic Type on iOS.
  static func displayFont(size: CGFloat, relativeTo style: Font.TextStyle, bold: Bool = false) -> Font {
    guard DisplayFace.isAvailable else { return .system(size: size, weight: bold ? .bold : .semibold, design: .rounded) }
    return .custom(DisplayFace.postScriptName(bold: bold), size: size, relativeTo: style)
  }
}
