// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

// MARK: - Modern Cheat Card
internal struct ModernCheatCard: View {
  let item: ModernCheatItem
  let index: Int
  let onToggle: (Bool) -> Void

  @State private var isEnabled: Bool
  @FocusState private var isFocused: Bool

  init(item: ModernCheatItem, index: Int, onToggle: @escaping (Bool) -> Void) {
    self.item = item
    self.index = index
    self.onToggle = onToggle
    self._isEnabled = State(initialValue: item.isEnabled)
  }

  var body: some View {
    Button(action: { toggleCheat() }) {
      VStack(alignment: .leading, spacing: 12) {
        // Header
        HStack {
          // Type Badge
          Text(item.type)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(item.typeColor)
            .clipShape(RoundedRectangle(cornerRadius: 6))

          Spacer()

          // Toggle
          ZStack {
            Circle()
              .fill(isEnabled ? .green : .white.opacity(0.3))
              .frame(width: 20, height: 20)

            if isEnabled {
              Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
            }
          }
          .contentShape(Rectangle())
          .buttonStyle(.plain)
          .focused($isFocused)
        }

        // Name
        Text(item.name)
          .font(.system(size: 16, weight: .semibold))
          .foregroundColor(.white)
          .multilineTextAlignment(.leading)
          .lineLimit(3)

        Spacer()
      }
      .padding(16)
      .frame(height: 120)
      .background(.white.opacity(isFocused ? 0.15 : 0.08))
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(.white.opacity(isFocused ? 0.3 : 0), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .modifier(FocusableCompat())
    .focused($isFocused)
  }

  private func toggleCheat() {
    let newState = !isEnabled
    onToggle(newState)
    isEnabled = newState
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
}

// MARK: - Modern Empty State
internal struct ModernEmptyState: View {
  @State private var isAnimating = false

  var body: some View {
    VStack(spacing: 20) {
      Image("DolphinLogo")
        .resizable()
        .scaledToFit()
        .frame(width: 64, height: 64)
        .foregroundColor(.white.opacity(0.6))
        .scaleEffect(isAnimating ? 1.1 : 1.0)
        .rotationEffect(.degrees(isAnimating ? 5 : -5))
        .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: isAnimating)
        .onAppear { isAnimating = true }

      VStack(spacing: 8) {
        Text(L("No Cheats Available"))
          .font(.system(size: 20, weight: .semibold))
          .foregroundColor(.white)

        Text(L("Download cheats to get started"))
          .font(.system(size: 16, weight: .medium))
          .foregroundColor(.white.opacity(0.6))
      }
    }
    .padding(40)
  }
}
