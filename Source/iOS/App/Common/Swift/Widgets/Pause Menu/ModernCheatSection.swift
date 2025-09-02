// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

// MARK: - Modern Cheat Section
internal struct ModernCheatSection: View {
  let title: String
  let codes: [ModernCheatItem]
  let onToggle: (Int, Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      // Section Header
      HStack {
        Text(title)
          .font(.system(size: 22, weight: .bold))
          .foregroundColor(.white)

        Spacer()

        Text("\(codes.count)" + " " + L("codes"))
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(.white.opacity(0.6))
      }

      // Codes Grid
      LazyVGrid(columns: [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
      ], spacing: 16) {
        ForEach(Array(codes.enumerated()), id: \.offset) { index, code in
          ModernCheatCard(
            item: code,
            index: index,
            onToggle: { enabled in
              onToggle(index, enabled)
            }
          )
        }
      }
    }
  }
}
