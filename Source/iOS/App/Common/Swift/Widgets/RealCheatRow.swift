// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

// Real cheat row component for displaying actual cheat codes
struct RealCheatRow: View {
  let title: String
  @State var isEnabled: Bool
  let isUserDefined: Bool
  let onToggle: (Bool) -> Void

  var body: some View {
    HStack(spacing: 16) {
      // Cheat info
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)

          if isUserDefined {
            Text(L("USER"))
              .font(.system(size: 10, weight: .bold))
              .foregroundColor(.orange)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.orange.opacity(0.2))
              .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
          }
        }

        Text(isEnabled ? L("Enabled") : L("Disabled"))
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(isEnabled ? .green : .white.opacity(0.7))
      }

      Spacer()

      // Toggle switch
      Button(action: {
        isEnabled.toggle()
        onToggle(isEnabled)
      }) {
        ZStack {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(isEnabled ? .green : .white.opacity(0.2))
            .frame(width: 50, height: 30)

          Circle()
            .fill(.white)
            .frame(width: 26, height: 26)
            .offset(x: isEnabled ? 10 : -10)
        }
      }
      .buttonStyle(.plain)
      .animation(.easeInOut(duration: 0.2), value: isEnabled)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(.white.opacity(0.05))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}
