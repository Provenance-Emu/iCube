// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The pause tile. tvOS keeps iFly's `TileFace`: a glyph over an uppercase title with the value in a corner chip.
/// iPhone and iPad draw no card at rest: a glass circle with the glyph in the tile's own colour, the title and value
/// beneath it, and Resume as a solid pill. A setting that is on fills its circle. A press or a pad's focus draws the
/// box. Used inside `ICubeCardButtonStyle`, which publishes focus as `\.icubeCardFocused`.
struct PauseCardFace: View {
  let item: MenuItem
  let prominent: Bool
  let isLead: Bool
  /// iPhone landscape: shorter cards, the glyph beside the title.
  var compact = false
  @Environment(\.icubeCardFocused) private var focused
  @Environment(\.icubePlatformAccent) private var platformAccent
  #if !os(tvOS)
  @Environment(\.horizontalSizeClass) private var sizeClass
  /// An iPad has the room for bigger cards.
  private var large: Bool { sizeClass == .regular && !compact }
  #endif

  private typealias Metrics = ICubeDesign.PauseCard

  private var value: String? {
    guard let value = item.currentValueTitle ?? item.badge, !value.isEmpty else { return nil }
    return value
  }

  var body: some View {
    #if os(tvOS)
    tvBody
    #else
    touchBody
    #endif
  }

  #if os(tvOS)
  private var tvBody: some View {
    let accent = platformAccent ?? ICubeDesign.color(.accent)
    let foreground: Color = item.role.isDestructive
      ? (item.tint ?? ICubeDesign.color(.destructive))
      : (focused ? .white : (isLead ? accent : ICubeDesign.color(.textPrimary)))
    return ZStack(alignment: .topTrailing) {
      VStack(spacing: Metrics.glyphTitleSpacing) {
        if let icon = item.icon {
          Image(systemName: icon)
            .font(Metrics.glyphFont(prominent: prominent))
        }
        // The size first: the font closest to the text wins, and the role still sets case and tracking.
        Text(item.title)
          .font(Metrics.titleFont)
          .icubeText(.nav)
          .lineLimit(2)
          // A gentle floor: a lower one shrank long titles below legibility.
          .minimumScaleFactor(Metrics.titleMinimumScale)
          .multilineTextAlignment(.center)
      }
      .padding(.horizontal, ICubeDesign.Spacing.xs.rawValue)
      .foregroundStyle(foreground)
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      if let value {
        PauseValueChip(text: value, focused: focused)
          .padding(Metrics.chipInset)
      }
    }
    .frame(height: Metrics.height(prominent: prominent))
    .icubeCardSurface(cornerRadius: Metrics.cornerRadius)
    .opacity(item.isEnabled ? 1 : Metrics.disabledOpacity)
    .accessibilityElement(children: .combine)
    .accessibilityValue(value ?? "")
  }
  #else
  private typealias Touch = Metrics.Touch

  private var size: Touch.Size {
    if compact { return .compact }
    return large ? .large : .regular
  }

  /// The tile's own colour from the model. Reset and Exit carry theirs; an untinted tile takes the platform accent.
  private var tone: Color {
    item.tint ?? (item.role.isDestructive ? ICubeDesign.color(.destructive) : platformAccent ?? ICubeDesign.color(.accent))
  }

  /// A toggle that is on, or a cycle with an Off position that is away from it (Fast Forward).
  private var isActive: Bool {
    switch item.role {
    case .toggle(let binding):
      return binding.wrappedValue
    case .cycle(let options, _):
      return options.contains { $0.0 == L("Off") } && value != L("Off")
    default:
      return false
    }
  }

  private var touchBody: some View {
    Group {
      if isLead { leadContent } else { cellContent }
    }
    .contentShape(Rectangle())
    .opacity(item.isEnabled ? 1 : Metrics.disabledOpacity)
    .accessibilityElement(children: .combine)
    .accessibilityValue(value ?? "")
  }

  /// Resume: dark ink on a solid pill, the one bright thing on the screen.
  private var leadContent: some View {
    let accent = platformAccent ?? ICubeDesign.color(.accent)
    return HStack(spacing: Touch.leadSpacing) {
      if let icon = item.icon {
        Image(systemName: icon).font(size.leadGlyphFont)
      }
      Text(item.title)
        .font(ICubeDesign.displayFont(size: size.leadTitle, relativeTo: .headline, bold: true))
        .lineLimit(1)
        .minimumScaleFactor(Touch.titleMinimumScale)
    }
    .foregroundStyle(Touch.leadInk)
    .padding(.horizontal, Touch.leadHorizontalPadding)
    .frame(maxWidth: .infinity)
    .frame(height: size.leadHeight)
    .background(Capsule().fill(Touch.leadFill))
    .overlay {
      if focused { Capsule().strokeBorder(accent, lineWidth: ICubeDesign.Card.borderWidth) }
    }
  }

  private var cellContent: some View {
    let accent = platformAccent ?? ICubeDesign.color(.accent)
    let shape = RoundedRectangle(cornerRadius: size.focusCornerRadius, style: .continuous)
    return VStack(spacing: size.cellSpacing) {
      glyph
      VStack(spacing: Touch.titleValueSpacing) {
        Text(item.title)
          .font(ICubeDesign.displayFont(size: size.title, relativeTo: .footnote))
          .foregroundStyle(ICubeDesign.color(.textPrimary))
          .multilineTextAlignment(.center)
          // A single word shrinks rather than breaking across two lines.
          .lineLimit(value == nil && item.title.contains(" ") ? 2 : 1)
          .minimumScaleFactor(Touch.titleMinimumScale)
        if let value {
          Text(value)
            .font(size.value)
            .foregroundStyle(ICubeDesign.color(.textSecondary))
            .lineLimit(1)
            .minimumScaleFactor(Touch.valueMinimumScale)
        }
      }
    }
    .padding(.horizontal, Touch.cellHorizontalPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .padding(.top, Touch.cellTopPadding)
    .frame(height: size.cellHeight)
    .background {
      if focused { shape.fill(ICubeDesign.Card.surface) }
    }
    .overlay {
      if focused { shape.strokeBorder(accent, lineWidth: ICubeDesign.Card.borderWidth) }
    }
  }

  @ViewBuilder private var glyph: some View {
    if let icon = item.icon {
      Image(systemName: icon)
        // The solid glyphs hold up at this size; a symbol with no fill form stays as it is.
        .symbolVariant(.fill)
        .font(size.glyphFont)
        .foregroundStyle(isActive ? Color.white : tone)
        .frame(width: size.circle, height: size.circle)
        .background {
          if isActive {
            Circle().fill(tone.gradient)
          } else {
            Circle().fill(Touch.glassFill)
          }
        }
        .overlay(Circle().strokeBorder(Touch.glassEdge, lineWidth: ICubeDesign.Line.hairline.rawValue))
    }
  }
  #endif
}

#if os(iOS)
/// The plain line under the iPhone and iPad tiles: what the focused or last touched tile does.
struct PauseHintLine: View {
  let text: String

  private typealias Touch = ICubeDesign.PauseCard.Touch

  var body: some View {
    Text(text)
      .font(Touch.hintFont)
      .foregroundStyle(ICubeDesign.color(.textSecondary))
      .multilineTextAlignment(.center)
      .lineLimit(2)
      .minimumScaleFactor(Touch.valueMinimumScale)
      .frame(maxWidth: .infinity)
      .frame(height: Touch.hintHeight)
      .id(text)
      .transition(.opacity)
      .animation(ICubeDesign.Motion.selection, value: text)
  }
}
#endif

#if os(tvOS)
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
        .font(Metrics.shelfGlyphFont)
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

#endif

extension ICubeDesign {
  /// Pause card and help-shelf geometry: iFly's 1080p numbers on tvOS (`TVPause`). The iPhone and iPad tile has its
  /// own (`PauseCard.Touch`).
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
    static let shelfFillOpacity: Double = TVPause.footerFillOpacity
    static let titleMinimumScale: CGFloat = 0.85
    static let shelfMinimumScale: CGFloat = 0.8
    static let focusedChipOpacity: Double = 0.35
    static let shelfBorderOpacity: Double = TVPause.footerBorderOpacity
    static var shelfGlyphFont: Font { .system(size: shelfGlyph, weight: .medium) }

    static func glyphFont(prominent: Bool) -> Font {
      .system(size: prominent ? Symbol.tilePrimary.rawValue : Symbol.tile.rawValue, weight: .medium)
    }

    static func height(prominent: Bool) -> CGFloat {
      prominent ? TVPause.primaryTileHeight : TVPause.tileHeight
    }
    #endif
    static let disabledOpacity: Double = 0.45
  }

  /// The display face at an explicit size (the type roles' sizes are fixed), following Dynamic Type on iOS.
  static func displayFont(size: CGFloat, relativeTo style: Font.TextStyle, bold: Bool = false) -> Font {
    guard DisplayFace.isAvailable else { return .system(size: size, weight: bold ? .bold : .semibold, design: .rounded) }
    return .custom(DisplayFace.postScriptName(bold: bold), size: size, relativeTo: style)
  }
}
