// Common/Swift/MenuKit/InfoShelf.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Fixed-height bar under a tile grid: the focused item's description, and its current value when it
/// has one. Keeps its height when there is nothing to say so the grid never jumps.
struct InfoShelf: View {
  let text: String?
  let value: String?
  /// tvOS: the focused item's name and glyph, shown above the description.
  var title: String? = nil
  var icon: String? = nil
  @Environment(\.icube) private var theme

  var body: some View {
    #if os(tvOS)
    tvBody
    #else
    touchBody
    #endif
  }

  #if os(tvOS)
  @Environment(\.icubePlatformAccent) private var platformAccent
  @Environment(\.icubeShelfHint) private var hint

  /// tvOS help bar under the pause grid (iFly layout): glyph, the item's name over its description, the
  /// value as a `tag`, and a Play/Pause remote hint on the trailing edge. Fixed height, so it never jumps.
  private var tvBody: some View {
    let tone = platformAccent ?? ICubeDesign.color(.accent)
    return HStack(spacing: ICubeDesign.Spacing.l.rawValue) {
      Image(systemName: icon ?? "info.circle")
        .font(ICubeDesign.symbolFont(.shelf))
        .foregroundStyle(tone)
        .frame(width: ICubeDesign.Spacing.xl.rawValue)
      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
        if let title {
          Text(title)
            .icubeText(.nav)
            .foregroundStyle(ICubeDesign.color(.textSecondary))
            .lineLimit(1)
        }
        Text(text ?? " ")
          .icubeText(.body)
          .foregroundStyle(ICubeDesign.color(.textPrimary))
          .lineLimit(2)
          .minimumScaleFactor(0.8)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: ICubeDesign.Spacing.l.rawValue)
      if let value, !value.isEmpty {
        Text(value)
          .icubeText(.tag)
          .foregroundStyle(tone)
          .padding(.horizontal, ICubeDesign.Spacing.xs.rawValue)
          .padding(.vertical, ICubeDesign.Spacing.xxs.rawValue)
          .background(Capsule().fill(tone.opacity(ICubeDesign.IconBadge.tintOpacity)))
      }
      if let hint {
        Label(hint, systemImage: "playpause.fill")
          .icubeText(.detail)
          .foregroundStyle(ICubeDesign.color(.textSecondary))
          .lineLimit(1)
          .fixedSize()
      }
    }
    .padding(.horizontal, ICubeDesign.Spacing.xl.rawValue)
    .padding(.vertical, ICubeDesign.Spacing.l.rawValue)
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: theme.shelfHeight)
    .icubePanel()
  }
  #endif

  private var touchBody: some View {
    HStack(spacing: 10) {
      Image(systemName: "info.circle")
        .foregroundStyle(.white.opacity(0.7))
      Text(text ?? " ")
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.85))
        .lineLimit(3)
      Spacer(minLength: 0)
      if let value, !value.isEmpty {
        Text(value)
          .font(.subheadline.weight(.semibold))
          .monospacedDigit()
          .foregroundStyle(.white)
      }
    }
    .padding(.horizontal, 16)
    .frame(maxWidth: .infinity, minHeight: theme.shelfHeight, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
        .fill(theme.tileFill)
    )
  }
}
