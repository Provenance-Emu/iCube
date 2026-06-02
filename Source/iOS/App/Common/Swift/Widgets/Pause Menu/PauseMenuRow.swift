// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

// Pause menu row component matching SettingsMenuRow styling
struct PauseMenuRow: View {
  let icon: String
  let title: String
  let subtitle: String
  let isDestructive: Bool
  let action: () -> Void

  init(icon: String, title: String, subtitle: String, isDestructive: Bool = false, action: @escaping () -> Void) {
    self.icon = icon
    self.title = title
    self.subtitle = subtitle
    self.isDestructive = isDestructive
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 20) {
        // Icon with background
        ZStack {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isDestructive ? .red.opacity(0.15) : .white.opacity(0.1))
            .frame(width: 48, height: 48)

          Image(systemName: icon)
            .font(.system(size: 20, weight: .medium))
            .foregroundColor(isDestructive ? .red : .white)
        }

        // Text content
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(isDestructive ? .red : .white)

          Text(subtitle)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(isDestructive ? .red.opacity(0.7) : .white.opacity(0.7))
        }

        Spacer()

        // Chevron
        Image(systemName: "chevron.right")
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(isDestructive ? .red.opacity(0.5) : .white.opacity(0.5))
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 16)
      .background(isDestructive ? .red.opacity(0.05) : .white.opacity(0.05))
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .buttonStyle(.plain)
  }
}
