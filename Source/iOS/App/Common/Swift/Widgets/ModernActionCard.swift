// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

// MARK: - Modern Action Card
internal struct ModernActionCard: View {
  let title: String
  let subtitle: String
  let icon: String
  let color: Color
  let isLoading: Bool
  let action: () -> Void

  @FocusState private var isFocused: Bool

  var body: some View {
    Button(action: action) {
      HStack(spacing: 16) {
        // Icon
        ZStack {
          Circle()
            .fill(color.opacity(0.2))
            .frame(width: 50, height: 50)

          if isLoading && isFocused {
            ProgressView()
              .progressViewStyle(CircularProgressViewStyle(tint: .white))
              .scaleEffect(0.8)
          } else {
            Image(systemName: icon)
              .font(.system(size: 24, weight: .semibold))
              .foregroundColor(color)
          }
        }

        // Text
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.system(size: 18, weight: .bold))
            .foregroundColor(.white)
          Text(subtitle)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white.opacity(0.7))
        }

        Spacer()

        // Arrow
        Image(systemName: "chevron.right")
          .font(.system(size: 16, weight: .semibold))
          .foregroundColor(.white.opacity(0.5))
      }
      .padding(20)
      .background(.white.opacity(isFocused ? 0.15 : 0.08))
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(color.opacity(isFocused ? 0.6 : 0), lineWidth: 2)
      )
    }
    .buttonStyle(.plain)
    .modifier(FocusableCompat())
    .focused($isFocused)
    .disabled(isLoading)
  }
}

private struct FocusableCompat: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 17, tvOS 17, *) {
      content.focusable()
    } else {
      content
    }
  }
}
