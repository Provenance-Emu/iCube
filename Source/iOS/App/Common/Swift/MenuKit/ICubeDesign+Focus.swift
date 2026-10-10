// Common/Swift/MenuKit/ICubeDesign+Focus.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The art half of the iCube card focus effect (spec §2.7), frozen from GameGridItem. Its 8 pt ring
/// and 2 pt highlight are not tokens and are used nowhere else. `ICubeCardFocusTests` pins it.
private struct ICubeCardArtFocus: ViewModifier {
  let isFocused: Bool

  func body(content: Content) -> some View {
    content
      .overlay(
        RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous)
          .stroke(
            LinearGradient(
              colors: isFocused ? [
                Color.cyan.opacity(0.95),
                Color(.dolphinTint).opacity(0.9),
                Color.purple.opacity(0.95),
                Color.cyan.opacity(0.95)
              ] : [Color.clear],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ),
            lineWidth: isFocused ? 8 : 0
          )
          .shadow(color: .cyan.opacity(isFocused ? 0.8 : 0), radius: isFocused ? 25 : 0)
          .shadow(color: .blue.opacity(isFocused ? 0.6 : 0), radius: isFocused ? 35 : 0)
          .shadow(color: .purple.opacity(isFocused ? 0.7 : 0), radius: isFocused ? 45 : 0)
          .animation(.easeInOut(duration: 0.6), value: isFocused)
      )
      .overlay(
        RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous)
          .stroke(Color.white.opacity(isFocused ? 0.4 : 0), lineWidth: isFocused ? 2 : 0)
          .padding(4)
          .animation(.easeInOut(duration: 0.4), value: isFocused)
      )
      .shadow(color: Color.black.opacity(isFocused ? 0.4 : 0.2), radius: isFocused ? 20 : 8, x: 0, y: isFocused ? 12 : 6)
      .overlay {
        // Top sheen while focused.
        if isFocused {
          VStack {
            LinearGradient(colors: [Color.white.opacity(0.2), .clear], startPoint: .top, endPoint: .center)
            Spacer()
          }
          .clipShape(RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous))
          .frame(width: LibraryLayout.cardSize.width, height: LibraryLayout.cardSize.height)
          .allowsHitTesting(false)
        }
      }
  }
}

/// The container half: lift, tilt (2° at rest, 5° focused) and shadow (spec §2.7).
private struct ICubeCardFocus: ViewModifier {
  let isFocused: Bool

  func body(content: Content) -> some View {
    content
      .scaleEffect(isFocused ? 1.08 : 1.0)
      .rotation3DEffect(.degrees(isFocused ? 5 : 2), axis: (x: 0.1, y: 1.0, z: 0), perspective: isFocused ? 0.8 : 1.0)
      .shadow(color: .black.opacity(isFocused ? 0.4 : 0.2), radius: isFocused ? 20 : 8, x: 0, y: isFocused ? 12 : 4)
      .animation(ICubeDesign.Motion.focusSpring, value: isFocused)
  }
}

extension View {
  /// Apply to the card art (cover or placeholder), inside the card's ZStack.
  func icubeCardArtFocus(isFocused: Bool) -> some View { modifier(ICubeCardArtFocus(isFocused: isFocused)) }

  /// Apply to the whole card (art + title), before its focus/gesture modifiers. A modifier, not a
  /// ButtonStyle: the card keeps its own tap, long-press, play/pause and context menu.
  func icubeCardFocus(isFocused: Bool) -> some View { modifier(ICubeCardFocus(isFocused: isFocused)) }
}
