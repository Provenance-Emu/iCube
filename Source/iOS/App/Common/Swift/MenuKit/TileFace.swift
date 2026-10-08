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
  @Environment(\.menuTheme) private var theme

  var body: some View {
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
        .font(.headline)
        .foregroundStyle(isDestructive ? .red : .white)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: theme.tileMinHeight, alignment: .leading)
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
