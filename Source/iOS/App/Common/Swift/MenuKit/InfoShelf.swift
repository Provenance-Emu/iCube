// Common/Swift/MenuKit/InfoShelf.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Fixed-height bar under a tile grid: the focused item's description, and its current value when it
/// has one. Keeps its height when there is nothing to say so the grid never jumps.
struct InfoShelf: View {
  let text: String?
  let value: String?
  @Environment(\.icube) private var theme

  var body: some View {
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
