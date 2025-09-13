// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct NeonGlowBorder: ViewModifier {
  let active: Bool
  let cornerRadius: CGFloat
  func body(content: Content) -> some View {
    content
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(
            LinearGradient(
              colors: [Color.cyan.opacity(0.9), Color.purple.opacity(0.9)],
              startPoint: .topLeading, endPoint: .bottomTrailing
            ), lineWidth: active ? 6 : 0
          )
          .opacity(active ? 1.0 : 0.0)
          .shadow(color: .cyan.opacity(active ? 0.6 : 0.0), radius: active ? 20 : 0, x: 0, y: 0)
          .shadow(color: .purple.opacity(active ? 0.5 : 0.0), radius: active ? 28 : 0, x: 0, y: 0)
      )
  }
}
