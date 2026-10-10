// Common/Swift/MenuKit/TileFace.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// One tile: icon badge top-left, value badge top-right, title bottom. The host wraps it in a `Button`
/// with `FocusButtonStyle`; the face itself has no gesture.
struct TileFace: View {
  let icon: String?
  let title: String
  let badge: String?
  let tint: Color
  let isDestructive: Bool
  let isEnabled: Bool
  /// Short variant for compact-height layouts (iPhone landscape): icon and title on one line.
  var isCompact: Bool = false
  @Environment(\.menuTheme) private var theme

  #if os(tvOS)
  private static let regularPadding: CGFloat = 14
  #else
  private static let regularPadding: CGFloat = 12
  #endif
  private static let compactMinHeight: CGFloat = 56
  private static let compactIconSize: CGFloat = 28

  private var compactContent: some View {
    HStack(spacing: 8) {
      if let icon {
        Image(systemName: icon)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(isDestructive ? .red : tint)
          .frame(width: Self.compactIconSize, height: Self.compactIconSize)
          .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .fill((isDestructive ? Color.red : tint).opacity(0.15))
          )
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.footnote.weight(.semibold))
          .foregroundStyle(isDestructive ? .red : .white)
          // A single word shrinks rather than hyphenating across two lines.
          .lineLimit(title.contains(" ") ? 2 : 1)
          .minimumScaleFactor(0.6)
          .multilineTextAlignment(.leading)
        if let badge, !badge.isEmpty {
          Text(badge)
            .font(.caption2.weight(.medium))
            .lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(.white.opacity(0.7))
        }
      }
      Spacer(minLength: 0)
    }
  }

  private var regularContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top) {
        if let icon {
          Image(systemName: icon)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(isDestructive ? .red : tint)
            .frame(width: 44, height: 44)
            .background(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((isDestructive ? Color.red : tint).opacity(0.15))
            )
        }
        Spacer(minLength: 0)
        if let badge, !badge.isEmpty {
          Text(badge)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.18)))
        }
      }
      Spacer(minLength: 0)
      Text(title)
        .font(theme.tileTitleFont)
        .foregroundStyle(isDestructive ? .red : .white)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
    }
  }

  var body: some View {
    Group {
      if isCompact { compactContent } else { regularContent }
    }
    .padding(isCompact ? 10 : Self.regularPadding)
    .frame(maxWidth: .infinity, minHeight: isCompact ? Self.compactMinHeight : theme.tileMinHeight, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
        .fill(theme.tileFill)
        .overlay(
          RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
            .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    )
    .opacity(isEnabled ? 1 : 0.45)
  }
}
